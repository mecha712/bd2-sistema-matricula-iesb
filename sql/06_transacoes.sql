-- #####################################################################
-- ##  06_transacoes.sql — TRANSAÇÕES E CONCORRÊNCIA                    ##
-- ##  A DISPUTA PELA ÚLTIMA VAGA                                       ##
-- ##  Projeto Acadêmico · Banco de Dados II (CCO072) · IESB · 2026/2   ##
-- ##  Frente: Transações e Concorrência                                ##
-- #####################################################################
--
-- O PROBLEMA
--   Matricular = (1) contar as vagas ocupadas, (2) se sobrou vaga, inserir.
--   Sozinho, funciona. Com dois alunos ao mesmo tempo disputando a ÚLTIMA
--   vaga, os dois fazem o passo (1) antes de qualquer um fazer o (2): os
--   dois veem "1 vaga livre", os dois inserem, e a turma fica com MAIS
--   alunos do que vagas (overbooking).
--
--   Nome técnico: WRITE SKEW (escrita enviesada). Cada transação lê o mesmo
--   dado (a contagem) e escreve uma linha DIFERENTE (cada uma a sua
--   matrícula). Como não escrevem na mesma linha, nenhuma bloqueia a outra.
--   No READ COMMITTED (o padrão do PostgreSQL) isso passa sem erro.
--
-- AS DUAS CORREÇÕES
--   1) BLOQUEIO EXPLÍCITO (pessimista): SELECT ... FOR UPDATE na linha da
--      TURMA antes de contar. Quem chega depois ESPERA na fila do bloqueio
--      e, quando passa, conta de novo já vendo a matrícula do primeiro.
--   2) NÍVEL DE ISOLAMENTO SERIALIZABLE (otimista): ninguém espera; o
--      PostgreSQL (SSI) detecta que as duas transações leram o que a outra
--      escreveu e ABORTA uma delas com o erro 40001 (serialization_failure).
--      A aplicação tem de repetir a transação; na repetição, a turma já
--      está cheia e a matrícula é recusada.
--   (REPEATABLE READ NÃO resolve: ele também deixa passar write skew.)
--
-- COMPARAÇÃO (o que o enunciado pede)
--   | critério        | FOR UPDATE (bloqueio)          | SERIALIZABLE (isolamento)        |
--   |-----------------|--------------------------------|----------------------------------|
--   | como evita      | fila no lock da linha da turma | detecta o conflito e aborta uma  |
--   | quem espera     | o 2º espera o 1º terminar      | ninguém espera                   |
--   | contenção       | alta numa turma disputada      | sem fila, mas mais abortos       |
--   |                 | (matrículas viram uma fila)    | quando a disputa é alta          |
--   | retentativa     | não precisa: o 2º decide com   | OBRIGATÓRIA: erro 40001 ->       |
--   |                 | o dado já atualizado           | repetir a transação inteira      |
--   | custo           | um lock de linha; barato       | rastreia leituras (SIREAD locks) |
--   |                 |                                | em toda transação serializável   |
--   | riscos          | deadlock se travar coisas em   | falsos positivos: pode abortar   |
--   |                 | ordens diferentes; esquecer o  | mesmo sem conflito real          |
--   |                 | FOR UPDATE em algum caminho    |                                  |
--   | abrangência     | só protege quem usa a função   | protege qualquer código que rode |
--   |                 | que trava                      | em SERIALIZABLE                  |
--   | quando usar     | ponto quente conhecido e regra | muitas regras/invariantes entre  |
--   |                 | simples (a vaga)               | linhas; prefere não ter fila     |
--   ESCOLHA DO PROJETO: a função oficial fn_matricular usa FOR UPDATE: a regra
--   é simples, o ponto de disputa é conhecido (a linha da turma) e o aluno
--   não pode receber "erro, tente de novo" no meio da matrícula.
--
-- COMO DEMONSTRAR (no pgAdmin, com duas abas de Query Tool no banco iesb):
--   0) CALL academico.pr_preparar_demo_vaga();   -- deixa 1 vaga na turma 2286
--   1) Anomalia: rode a aba A e, durante os 10 s de espera dela, a aba B
--        aba A: SELECT academico.fn_matricular_sem_controle(2049, 2286, 10);
--        aba B: SELECT academico.fn_matricular_sem_controle(2050, 2286, 0);
--      e confira: SELECT * FROM academico.vw_demo_vaga;  -> restantes = -1
--   2) Correção 1 (FOR UPDATE): rode o passo 0 e repita com fn_matricular
--      no lugar de fn_matricular_sem_controle: a aba B fica ESPERANDO e,
--      quando a A termina, é recusada (turma lotada).
--   3) Correção 2 (SERIALIZABLE): rode o passo 0 e repita o passo 1, mas
--      com cada SELECT entre BEGIN ISOLATION LEVEL SERIALIZABLE; e COMMIT;
--      uma das duas recebe o erro 40001 (could not serialize access).
-- Este script só CRIA as funções e prepara a turma da disputa.
-- =====================================================================

SET search_path TO academico, public;


-- =====================================================================
-- 1. VERSÃO INGÊNUA (reproduz a anomalia)
-- Conta, espera p_pausa_seg segundos (para dar tempo de a outra sessão
-- entrar na disputa ao vivo) e insere. Sem nenhuma proteção.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_matricular_sem_controle(
  p_aluno_id  int,
  p_turma_id  int,
  p_pausa_seg numeric DEFAULT 0)
RETURNS int
LANGUAGE plpgsql
SET search_path = academico, pg_catalog, pg_temp
AS $$
DECLARE
  v_vagas    int;
  v_ocupadas int;
  v_id       int;
BEGIN
  SELECT vagas INTO v_vagas FROM turma WHERE id = p_turma_id;            -- SEM trava
  SELECT count(*) INTO v_ocupadas
    FROM matricula WHERE turma_id = p_turma_id AND status = 'MATRICULADO';

  RAISE NOTICE '[%] li % de % vagas ocupadas', clock_timestamp()::time(0), v_ocupadas, v_vagas;
  IF v_ocupadas >= v_vagas THEN
    RAISE EXCEPTION 'Turma lotada: % de % vagas ocupadas', v_ocupadas, v_vagas;
  END IF;

  PERFORM pg_sleep(p_pausa_seg);                     -- a "janela" da corrida

  INSERT INTO matricula (aluno_id, turma_id) VALUES (p_aluno_id, p_turma_id)
  RETURNING id INTO v_id;
  RAISE NOTICE '[%] matrícula % gravada', clock_timestamp()::time(0), v_id;
  RETURN v_id;
END $$;


-- =====================================================================
-- 2. CORREÇÃO 1 — BLOQUEIO EXPLÍCITO (versão oficial do sistema)
-- Além da vaga, valida as regras de negócio da matrícula.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_matricular(
  p_aluno_id  int,
  p_turma_id  int,
  p_pausa_seg numeric DEFAULT 0)
RETURNS int
LANGUAGE plpgsql
SET search_path = academico, pg_catalog, pg_temp
AS $$
DECLARE
  v_turma    turma%ROWTYPE;
  v_ocupadas int;
  v_id       int;
BEGIN
  -- O PONTO-CHAVE: FOR UPDATE trava a linha da turma até o fim da transação.
  -- Uma segunda matrícula na MESMA turma para aqui e espera. Matrículas em
  -- turmas diferentes não se atrapalham (o lock é só desta linha).
  SELECT * INTO v_turma FROM turma WHERE id = p_turma_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Turma % não existe', p_turma_id;
  END IF;
  RAISE NOTICE '[%] trava da turma % obtida', clock_timestamp()::time(0), v_turma.codigo;

  IF NOT EXISTS (SELECT 1 FROM periodo_letivo WHERE id = v_turma.periodo_letivo_id AND vigente) THEN
    RAISE EXCEPTION 'A turma % não é do período vigente', v_turma.codigo;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM aluno WHERE id = p_aluno_id AND situacao = 'ATIVO') THEN
    RAISE EXCEPTION 'Aluno % inexistente ou não está ativo', p_aluno_id;
  END IF;

  -- já aprovado na disciplina?
  IF EXISTS (SELECT 1
               FROM matricula m
               JOIN turma t     ON t.id = m.turma_id
               JOIN historico h ON h.matricula_id = m.id
              WHERE m.aluno_id = p_aluno_id
                AND t.disciplina_id = v_turma.disciplina_id
                AND h.situacao = 'APROVADO') THEN
    RAISE EXCEPTION 'Aluno % já foi aprovado nesta disciplina', p_aluno_id;
  END IF;

  -- todos os pré-requisitos diretos aprovados?
  IF EXISTS (SELECT 1
               FROM pre_requisito pr
              WHERE pr.disciplina_id = v_turma.disciplina_id
                AND NOT EXISTS (SELECT 1
                                  FROM matricula m
                                  JOIN turma t     ON t.id = m.turma_id
                                  JOIN historico h ON h.matricula_id = m.id
                                 WHERE m.aluno_id = p_aluno_id
                                   AND t.disciplina_id = pr.requisito_id
                                   AND h.situacao = 'APROVADO')) THEN
    RAISE EXCEPTION 'Aluno % não cumpriu os pré-requisitos da disciplina', p_aluno_id;
  END IF;

  -- Esta contagem é um comando NOVO: no READ COMMITTED ela enxerga tudo o
  -- que já foi confirmado, inclusive a matrícula de quem estava na frente
  -- na fila do FOR UPDATE.
  SELECT count(*) INTO v_ocupadas
    FROM matricula WHERE turma_id = p_turma_id AND status = 'MATRICULADO';
  RAISE NOTICE '[%] li % de % vagas ocupadas', clock_timestamp()::time(0), v_ocupadas, v_turma.vagas;

  IF v_ocupadas >= v_turma.vagas THEN
    RAISE EXCEPTION 'Turma % lotada: % de % vagas ocupadas', v_turma.codigo, v_ocupadas, v_turma.vagas;
  END IF;

  PERFORM pg_sleep(p_pausa_seg);         -- segura a trava (só para a demonstração)

  INSERT INTO matricula (aluno_id, turma_id) VALUES (p_aluno_id, p_turma_id)
  RETURNING id INTO v_id;
  RAISE NOTICE '[%] matrícula % gravada', clock_timestamp()::time(0), v_id;
  RETURN v_id;
END $$;

COMMENT ON FUNCTION fn_matricular(int, int, numeric) IS
  'Matrícula oficial: valida regras e usa SELECT ... FOR UPDATE na turma contra a corrida pela última vaga';


-- =====================================================================
-- 3. A TURMA DA DISPUTA
-- CCO072 (Banco de Dados II), turma CCONM5B de 2026/2. Os dois candidatos
-- são alunos de CCO do noturno, aptos a cursar BD II (aprovados em BD I) e
-- que ainda não se matricularam. A carga (02) deixou os dois de fora de
-- propósito.
-- =====================================================================
DROP TABLE IF EXISTS demo_concorrencia;
CREATE TABLE demo_concorrencia (
  id          smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),   -- tabela de uma linha só
  turma_id    int NOT NULL REFERENCES turma (id),
  aluno_a_id  int NOT NULL REFERENCES aluno (id),
  aluno_b_id  int NOT NULL REFERENCES aluno (id)
);
COMMENT ON TABLE demo_concorrencia IS 'Apoio à demonstração: a turma e os dois alunos da disputa pela última vaga';

INSERT INTO demo_concorrencia (turma_id, aluno_a_id, aluno_b_id)
SELECT (SELECT t.id
          FROM turma t
          JOIN disciplina d     ON d.id = t.disciplina_id AND d.codigo = 'CCO072'
          JOIN periodo_letivo p ON p.id = t.periodo_letivo_id AND p.vigente
         WHERE t.codigo = 'CCONM5B'),
       (SELECT id FROM aluno WHERE matricula = '2024200149'),   -- Giovanna
       (SELECT id FROM aluno WHERE matricula = '2024200150');   -- Lucas

-- Situação da disputa, a qualquer momento
CREATE OR REPLACE VIEW vw_demo_vaga AS
SELECT t.id                                   AS turma_id,
       d.codigo || ' ' || t.codigo            AS turma,
       t.vagas,
       v.ocupadas,
       t.vagas - v.ocupadas                   AS restantes,
       (SELECT matricula || ' ' || nome FROM aluno WHERE id = dc.aluno_a_id) AS aluno_a,
       EXISTS (SELECT 1 FROM matricula WHERE turma_id = t.id AND aluno_id = dc.aluno_a_id) AS a_matriculado,
       (SELECT matricula || ' ' || nome FROM aluno WHERE id = dc.aluno_b_id) AS aluno_b,
       EXISTS (SELECT 1 FROM matricula WHERE turma_id = t.id AND aluno_id = dc.aluno_b_id) AS b_matriculado
  FROM demo_concorrencia dc
  JOIN turma t      ON t.id = dc.turma_id
  JOIN disciplina d ON d.id = t.disciplina_id
 CROSS JOIN LATERAL (SELECT count(*) AS ocupadas
                       FROM matricula m
                      WHERE m.turma_id = t.id AND m.status = 'MATRICULADO') v;

-- Reinicia a disputa: tira A e B da turma e deixa exatamente 1 vaga livre.
-- PROCEDURE (e não função) porque é uma ação, não devolve valor: CALL.
CREATE OR REPLACE PROCEDURE pr_preparar_demo_vaga()
LANGUAGE plpgsql
SET search_path = academico, pg_catalog, pg_temp
AS $$
DECLARE
  v demo_concorrencia%ROWTYPE;
BEGIN
  SELECT * INTO v FROM demo_concorrencia;
  -- se alguém lançou histórico para eles (ex.: script da Aula 2), apaga antes
  DELETE FROM historico
   WHERE matricula_id IN (SELECT id FROM matricula
                           WHERE turma_id = v.turma_id
                             AND aluno_id IN (v.aluno_a_id, v.aluno_b_id));
  DELETE FROM matricula
   WHERE turma_id = v.turma_id
     AND aluno_id IN (v.aluno_a_id, v.aluno_b_id);
  UPDATE turma
     SET vagas = (SELECT count(*) FROM matricula
                   WHERE turma_id = v.turma_id AND status = 'MATRICULADO') + 1
   WHERE id = v.turma_id;
  RAISE NOTICE 'Disputa pronta: resta exatamente 1 vaga na turma %', v.turma_id;
END $$;

CALL pr_preparar_demo_vaga();
SELECT * FROM vw_demo_vaga;
