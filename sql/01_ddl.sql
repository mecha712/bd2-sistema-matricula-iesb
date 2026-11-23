-- #####################################################################
-- ##  01_ddl.sql — DEFINIÇÃO DE DADOS E RESTRIÇÕES DE INTEGRIDADE      ##
-- ##  Projeto Acadêmico · Banco de Dados II (CCO072) · IESB · 2026/2   ##
-- ##  Frente: Modelagem Física e Desempenho                            ##
-- #####################################################################
--
-- O QUE ESTE SCRIPT FAZ
--   Cria do zero o schema "academico" com todas as tabelas, tipos,
--   domínios, chaves, colunas geradas e restrições de integridade do
--   Sistema de Matrícula Acadêmica.
--
-- COMO RODAR
--   Conectado ao banco "iesb" (no Docker do projeto isso é automático).
--   Pode rodar de novo quando quiser: ele apaga o schema e recria tudo.
--   Depois dele vem o 02_carga.sql.
--
-- COMPATIBILIDADE
--   Os nomes de tabelas e colunas seguem o banco usado pelo professor na
--   Aula 2 (aluno, curso, disciplina, pre_requisito, periodo_letivo, turma,
--   matricula, historico). O arquivo da Aula 2 roda inteiro sobre este banco.
--   Testado no PostgreSQL 16 e escrito para o 17 (ambiente oficial).
--
-- O MODELO EM UMA FRASE
--   Um CURSO tem um CURRÍCULO (lista de DISCIPLINAS por semestre). Cada
--   disciplina pode exigir outras (PRÉ-REQUISITO). A cada PERÍODO LETIVO
--   abrem-se TURMAS de cada disciplina, com HORÁRIOS em SALAS. O ALUNO se
--   MATRICULA em turmas, e cada matrícula gera um registro de HISTÓRICO
--   (notas, frequência e situação).
-- =====================================================================


-- =====================================================================
-- 0. SCHEMA, EXTENSÕES E CONFIGURAÇÃO DO BANCO
-- =====================================================================

-- Recomeça limpo. CASCADE apaga junto tudo o que estiver dentro do schema.




DROP SCHEMA IF EXISTS academico CASCADE;
CREATE SCHEMA academico;
COMMENT ON SCHEMA academico IS
  'Sistema de Matrícula Acadêmica - Projeto BD II (CCO072) IESB 2026/2';





-- Extensões que vêm junto com o PostgreSQL (pacote contrib):
--   btree_gist: permite usar "=" de números dentro de um índice GiST.
--               É o que viabiliza a restrição EXCLUDE de choque de sala.
--   pg_trgm   : busca por trecho de texto (trigramas), usada num índice GIN
--               para procurar aluno por parte do nome (script 05).
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm    WITH SCHEMA public;

-- search_path: onde o PostgreSQL procura as tabelas sem o nome do schema.
-- SET vale para esta sessão; ALTER DATABASE grava como padrão do banco,
-- para toda conexão nova (pgAdmin, psql, CloudBeaver) já cair no academico.
SET search_path TO academico, public;

DO $$
BEGIN
  EXECUTE format('ALTER DATABASE %I SET search_path TO academico, public', current_database());
  EXECUTE format('ALTER DATABASE %I SET timezone TO %L', current_database(), 'America/Sao_Paulo');
END $$;
SET timezone TO 'America/Sao_Paulo';


-- =====================================================================
-- 1. TIPOS ENUMERADOS (ENUM)
-- ---------------------------------------------------------------------
-- O QUE É: um tipo com uma lista FECHADA de valores válidos.
-- POR QUE AQUI: status e situações têm poucos valores, fixos e que quase
--   nunca mudam. O ENUM recusa qualquer valor fora da lista e ocupa 4 bytes.
-- QUANDO NÃO USAR: se a lista mudar com frequência ou precisar de atributos
--   próprios (descrição, ordem, ativo), o certo é uma tabela de domínio.
-- =====================================================================


    CREATE TYPE tp_status_matricula   AS ENUM ('MATRICULADO', 'TRANCADO', 'CANCELADO', 'CONCLUIDO');
CREATE TYPE tp_situacao_historico AS ENUM ('CURSANDO', 'APROVADO', 'REPROVADO_NOTA', 'REPROVADO_FALTA');
CREATE TYPE tp_situacao_aluno     AS ENUM ('ATIVO', 'TRANCADO', 'DESLIGADO', 'FORMADO');
CREATE TYPE tp_turno              AS ENUM ('MATUTINO', 'VESPERTINO', 'NOTURNO');
CREATE TYPE tp_grau               AS ENUM ('BACHARELADO', 'LICENCIATURA', 'TECNOLOGO');
CREATE TYPE tp_tipo_sala          AS ENUM ('SALA', 'LABORATORIO', 'AUDITORIO');


-- Tipo INTERVALO DE HORÁRIO (range de time). O PostgreSQL já tem ranges de
-- número e de data; de hora não. Criamos um para o EXCLUDE de choque de sala:
-- timerange('19:00','20:40') && timerange('20:00','21:00')  ->  true (sobrepõe)
CREATE TYPE timerange AS RANGE (subtype = time);


-- =====================================================================
-- 2. DOMÍNIOS (DOMAIN)
-- ---------------------------------------------------------------------
-- O QUE É: um tipo base + uma regra (CHECK), com nome, reaproveitável.
-- POR QUE: a regra "nota vai de 0 a 10" é escrita UMA vez e vale em todas
--   as colunas de nota. Se a regra mudar, muda num lugar só.
-- LEMBRETE: o tipo limita o TAMANHO; o CHECK limita o
--   INTERVALO. NUMERIC(4,2) aceita 99,99; só o CHECK barra a nota 11.
-- =====================================================================

-- Validação de CPF pelos dígitos verificadores (regra oficial da Receita).
-- IMMUTABLE: mesma entrada, mesma saída -> pode ser usada em CHECK e índice.
-- SET search_path: boa prática de segurança e exigência do PostgreSQL 17
-- (manutenção e restauração rodam com search_path vazio).
CREATE FUNCTION fn_cpf_valido(p_cpf text)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  soma  int;
  digito int;
  i     int;
BEGIN
  -- 11 dígitos e não pode ser tudo igual (111.111.111-11 passa na conta, mas é inválido)
  IF p_cpf !~ '^[0-9]{11}$' OR p_cpf ~ '^([0-9])\1{10}$' THEN
    RETURN false;
  END IF;
  -- 1º dígito verificador: pesos 10..2 sobre os 9 primeiros dígitos
  soma := 0;
  FOR i IN 1..9 LOOP
    soma := soma + substr(p_cpf, i, 1)::int * (11 - i);
  END LOOP;
  digito := (soma * 10) % 11 % 10;
  IF digito <> substr(p_cpf, 10, 1)::int THEN
    RETURN false;
  END IF;
  -- 2º dígito verificador: pesos 11..2 sobre os 10 primeiros dígitos
  soma := 0;
  FOR i IN 1..10 LOOP
    soma := soma + substr(p_cpf, i, 1)::int * (12 - i);
  END LOOP;
  digito := (soma * 10) % 11 % 10;
  RETURN digito = substr(p_cpf, 11, 1)::int;
END $$;
COMMENT ON FUNCTION fn_cpf_valido(text) IS 'true se o CPF (11 dígitos) tem dígitos verificadores válidos';

CREATE DOMAIN dm_cpf               AS CHAR(11)     CHECK (fn_cpf_valido(VALUE));
CREATE DOMAIN dm_matricula_aluno   AS CHAR(10)     CHECK (VALUE ~ '^[0-9]{10}$');
CREATE DOMAIN dm_codigo_disciplina AS CHAR(6)      CHECK (VALUE ~ '^[A-Z]{3}[0-9]{3}$');
CREATE DOMAIN dm_email             AS VARCHAR(120) CHECK (VALUE ~ '^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)+$');
CREATE DOMAIN dm_nota              AS NUMERIC(4,2) CHECK (VALUE BETWEEN 0 AND 10);
CREATE DOMAIN dm_percentual        AS NUMERIC(5,2) CHECK (VALUE BETWEEN 0 AND 100);
CREATE DOMAIN dm_dia_semana        AS SMALLINT     CHECK (VALUE BETWEEN 1 AND 7);  -- 1 = segunda ... 7 = domingo (ISO)

COMMENT ON DOMAIN dm_nota       IS 'Nota de 0,00 a 10,00 (tipo exato NUMERIC; nunca FLOAT)';
COMMENT ON DOMAIN dm_percentual IS 'Percentual de 0 a 100 (frequência)';


-- =====================================================================
-- 3. TABELAS
-- ---------------------------------------------------------------------
-- Convenções:
--   * Chave primária artificial: INT GENERATED ALWAYS AS IDENTITY.
--     ALWAYS (e não BY DEFAULT): ninguém "inventa" um id na mão; o banco
--     é o único que numera. É o padrão SQL; o SERIAL é o jeito antigo.
--   * Chaves naturais (matrícula do aluno, CPF, código da disciplina) viram
--     UNIQUE: são as chaves CANDIDATAS que não foram escolhidas (alternativas).
--   * Toda FK diz o que fazer quando o pai é apagado. O padrão aqui é
--     RESTRICT (recusa); CASCADE só onde o filho não existe sem o pai.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 3.1 PERÍODO LETIVO (ex.: 2026/2)
-- ---------------------------------------------------------------------
CREATE TABLE periodo_letivo (
  id           INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ano          SMALLINT NOT NULL CHECK (ano BETWEEN 2000 AND 2100),
  semestre     SMALLINT NOT NULL CHECK (semestre IN (1, 2)),
  data_inicio  DATE     NOT NULL,
  data_fim     DATE     NOT NULL,
  vigente      BOOLEAN  NOT NULL DEFAULT false,
  CONSTRAINT uq_periodo_ano_semestre UNIQUE (ano, semestre),
  CONSTRAINT ck_periodo_datas        CHECK (data_fim > data_inicio),
  CONSTRAINT ck_periodo_ano_coerente CHECK (extract(year FROM data_inicio) = ano),
  -- EXCLUDE: dois períodos não podem se sobrepor no calendário.
  -- "[]" = intervalo fechado nas duas pontas; && = "se sobrepõe a".
  CONSTRAINT ex_periodo_sem_sobreposicao
    EXCLUDE USING gist (daterange(data_inicio, data_fim, '[]') WITH &&)
);
-- ÍNDICE ÚNICO PARCIAL como regra de negócio: no máximo UM período vigente.
-- Só as linhas com vigente = true entram no índice; como o valor indexado é
-- sempre "true", a segunda linha vigente violaria a unicidade.
CREATE UNIQUE INDEX uq_periodo_um_vigente ON periodo_letivo (vigente) WHERE vigente;

COMMENT ON TABLE periodo_letivo IS 'Semestres letivos; exatamente um pode estar vigente';


-- ---------------------------------------------------------------------
-- 3.2 CURSO
-- ---------------------------------------------------------------------
CREATE TABLE curso (
  id                 INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo             VARCHAR(10)  NOT NULL UNIQUE CHECK (codigo ~ '^[A-Z]{2,10}$'),
  nome               VARCHAR(100) NOT NULL,
  grau               tp_grau      NOT NULL,
  duracao_semestres  SMALLINT     NOT NULL CHECK (duracao_semestres BETWEEN 4 AND 12),
  ativo              BOOLEAN      NOT NULL DEFAULT true
);
COMMENT ON TABLE curso IS 'Cursos de graduação ofertados';


-- ---------------------------------------------------------------------
-- 3.3 CURRÍCULO (a "matriz curricular" de um curso; pode haver versões)
-- ---------------------------------------------------------------------
CREATE TABLE curriculo (
  id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  curso_id  INT         NOT NULL REFERENCES curso (id) ON DELETE RESTRICT,
  versao    VARCHAR(10) NOT NULL,
  vigente   BOOLEAN     NOT NULL DEFAULT true,
  CONSTRAINT uq_curriculo_curso_versao UNIQUE (curso_id, versao)
);
-- Outro único parcial de regra: cada curso tem no máximo UM currículo vigente.
CREATE UNIQUE INDEX uq_curriculo_um_vigente_por_curso ON curriculo (curso_id) WHERE vigente;

COMMENT ON TABLE curriculo IS 'Versões da matriz curricular de cada curso';


-- ---------------------------------------------------------------------
-- 3.4 DISCIPLINA
-- ---------------------------------------------------------------------
CREATE TABLE disciplina (
  id          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo      dm_codigo_disciplina NOT NULL UNIQUE,     -- ex.: CCO072
  nome        VARCHAR(100) NOT NULL,
  ch_teorica  SMALLINT     NOT NULL DEFAULT 0 CHECK (ch_teorica >= 0),
  ch_pratica  SMALLINT     NOT NULL DEFAULT 0 CHECK (ch_pratica >= 0),
  -- COLUNA GERADA: o banco calcula e grava sozinho. Ninguém consegue gravar
  -- um total que não bata com teórica + prática (atributo DERIVADO).
  ch_total    SMALLINT GENERATED ALWAYS AS (ch_teorica + ch_pratica) STORED,
  ementa      TEXT,
  CONSTRAINT ck_disciplina_carga_positiva CHECK (ch_teorica + ch_pratica > 0)
);
COMMENT ON TABLE  disciplina          IS 'Disciplinas (componentes curriculares)';
COMMENT ON COLUMN disciplina.ch_total IS 'Coluna gerada: ch_teorica + ch_pratica';


-- ---------------------------------------------------------------------
-- 3.5 CURRÍCULO x DISCIPLINA (N:N -> tabela associativa)
-- Um currículo tem várias disciplinas; uma disciplina está em vários
-- currículos (Banco de Dados II está em CCO, ESW e ADS). O semestre ideal
-- é atributo DO PAR: CCO072 pode ser do 5º semestre num curso e do 4º noutro.
-- ---------------------------------------------------------------------
CREATE TABLE curriculo_disciplina (
  curriculo_id    INT      NOT NULL REFERENCES curriculo (id)  ON DELETE CASCADE,
  disciplina_id   INT      NOT NULL REFERENCES disciplina (id) ON DELETE RESTRICT,
  semestre_ideal  SMALLINT NOT NULL CHECK (semestre_ideal BETWEEN 1 AND 12),
  obrigatoria     BOOLEAN  NOT NULL DEFAULT true,
  PRIMARY KEY (curriculo_id, disciplina_id)
);
COMMENT ON TABLE curriculo_disciplina IS 'Associativa N:N currículo x disciplina, com o semestre ideal do par';


-- ---------------------------------------------------------------------
-- 3.6 PRÉ-REQUISITO (N:N da disciplina com ela mesma: auto-relacionamento)
-- (disciplina_id) exige ter sido aprovado em (requisito_id).
-- ---------------------------------------------------------------------
CREATE TABLE pre_requisito (
  disciplina_id  INT NOT NULL REFERENCES disciplina (id) ON DELETE CASCADE,
  requisito_id   INT NOT NULL REFERENCES disciplina (id) ON DELETE RESTRICT,
  PRIMARY KEY (disciplina_id, requisito_id),
  CONSTRAINT ck_prereq_nao_exige_a_si_mesma CHECK (disciplina_id <> requisito_id)
);
COMMENT ON TABLE pre_requisito IS 'disciplina_id exige aprovação prévia em requisito_id (sem ciclos: ver gatilho)';


-- ---------------------------------------------------------------------
-- 3.7 SALA
-- ---------------------------------------------------------------------
CREATE TABLE sala (
  id          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo      VARCHAR(10)  NOT NULL UNIQUE,                 -- ex.: A-101, LAB-07
  bloco       CHAR(1)      NOT NULL CHECK (bloco ~ '^[A-Z]$'),
  capacidade  SMALLINT     NOT NULL CHECK (capacidade BETWEEN 1 AND 300),
  tipo        tp_tipo_sala NOT NULL DEFAULT 'SALA'
);
COMMENT ON TABLE sala IS 'Salas de aula e laboratórios do campus';


-- ---------------------------------------------------------------------
-- 3.8 TURMA (a oferta de uma disciplina num período, ex.: CCO072 / CCONM5A)
-- ---------------------------------------------------------------------
CREATE TABLE turma (
  id                 INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo             VARCHAR(10) NOT NULL CHECK (codigo ~ '^[A-Z0-9]{4,10}$'),
  disciplina_id      INT         NOT NULL REFERENCES disciplina (id)     ON DELETE RESTRICT,
  periodo_letivo_id  INT         NOT NULL REFERENCES periodo_letivo (id) ON DELETE RESTRICT,
  turno              tp_turno    NOT NULL,
  vagas              SMALLINT    NOT NULL CHECK (vagas BETWEEN 1 AND 200),
  -- o mesmo código de turma (ex.: CCONM5A) se repete em várias disciplinas,
  -- mas não pode repetir na mesma disciplina e no mesmo período:
  CONSTRAINT uq_turma_periodo_disciplina_codigo UNIQUE (periodo_letivo_id, disciplina_id, codigo),
  -- superchave usada como ALVO da FK composta de turma_horario (ver 3.9)
  CONSTRAINT uq_turma_id_periodo UNIQUE (id, periodo_letivo_id)
);
COMMENT ON TABLE turma IS 'Oferta de uma disciplina em um período letivo, com número de vagas';


-- ---------------------------------------------------------------------
-- 3.9 HORÁRIO DA TURMA (entidade FRACA de turma)
-- Uma turma tem VÁRIOS encontros por semana: atributo multivalorado -> vira
-- tabela (é exatamente o que a 1FN manda). Não existe sem a turma: a chave
-- é a da dona (turma_id) + discriminador (dia, hora) e a FK é ON DELETE CASCADE.
--
-- Por que periodo_letivo_id está aqui se a turma já tem? Porque a restrição
-- EXCLUDE só enxerga colunas da PRÓPRIA linha, e a mesma sala pode ser usada
-- no mesmo horário em semestres diferentes. A FK COMPOSTA (turma_id,
-- periodo_letivo_id) -> turma(id, periodo_letivo_id) garante que esse valor
-- é sempre igual ao da turma: redundância controlada, sem risco de divergir
-- (e ON UPDATE CASCADE acompanha se o período da turma mudar).
-- ---------------------------------------------------------------------
CREATE TABLE turma_horario (
  turma_id           INT           NOT NULL,
  periodo_letivo_id  INT           NOT NULL,
  dia_semana         dm_dia_semana NOT NULL,
  hora_inicio        TIME          NOT NULL,
  hora_fim           TIME          NOT NULL,
  sala_id            INT           NOT NULL REFERENCES sala (id) ON DELETE RESTRICT,
  PRIMARY KEY (turma_id, dia_semana, hora_inicio),
  CONSTRAINT fk_horario_turma FOREIGN KEY (turma_id, periodo_letivo_id)
    REFERENCES turma (id, periodo_letivo_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_horario_intervalo CHECK (hora_fim > hora_inicio),
  -- A mesma SALA não pode ter dois encontros que se sobrepõem no mesmo dia
  -- e no mesmo período. Um UNIQUE não resolve (19:00-20:40 e 20:00-21:30 são
  -- diferentes, mas chocam). O EXCLUDE compara com "&&" (sobreposição).
  CONSTRAINT ex_sala_sem_choque EXCLUDE USING gist (
    periodo_letivo_id WITH =,
    sala_id           WITH =,
    dia_semana        WITH =,
    timerange(hora_inicio, hora_fim) WITH &&),
  -- E a mesma turma não pode ter dois encontros sobrepostos.
  CONSTRAINT ex_turma_sem_choque EXCLUDE USING gist (
    turma_id   WITH =,
    dia_semana WITH =,
    timerange(hora_inicio, hora_fim) WITH &&)
);
COMMENT ON TABLE turma_horario IS 'Encontros semanais de cada turma (dia, faixa de horário e sala)';


-- ---------------------------------------------------------------------
-- 3.10 ALUNO
-- ---------------------------------------------------------------------
CREATE TABLE aluno (
  id                   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  matricula            dm_matricula_aluno NOT NULL UNIQUE,     -- RA, ex.: 2024200015
  nome                 VARCHAR(120)       NOT NULL,
  cpf                  dm_cpf             NOT NULL UNIQUE,     -- chave candidata (alternativa)
  email                dm_email           NOT NULL UNIQUE,
  data_nascimento      DATE               NOT NULL CHECK (data_nascimento >= DATE '1920-01-01'),
  -- (0,1): o aluno PODE não ter curso (aluno especial / ainda sem curso).
  -- Por isso a FK aceita nulo: a cardinalidade MÍNIMA decide o NOT NULL.
  curso_id             INT                REFERENCES curso (id) ON DELETE RESTRICT,
  periodo_ingresso_id  INT                NOT NULL REFERENCES periodo_letivo (id) ON DELETE RESTRICT,
  turno                tp_turno           NOT NULL DEFAULT 'NOTURNO',
  situacao             tp_situacao_aluno  NOT NULL DEFAULT 'ATIVO',
  -- Papel (role) do PostgreSQL com que o aluno se autentica. É a ponte entre
  -- a linha do aluno e o usuário do banco que a política de RLS compara
  -- com current_user (script 07). 63 = tamanho máximo de nome no PostgreSQL.
  login_bd             VARCHAR(63)        UNIQUE,
  criado_em            TIMESTAMPTZ        NOT NULL DEFAULT now()
);
COMMENT ON TABLE  aluno          IS 'Alunos; curso_id nulo = aluno especial (sem curso)';
COMMENT ON COLUMN aluno.login_bd IS 'Nome do papel de login no PostgreSQL (usado pelo RLS)';


-- ---------------------------------------------------------------------
-- 3.11 MATRÍCULA (N:N aluno x turma -> tabela associativa)
-- Um aluno cursa várias turmas; uma turma tem vários alunos. A matrícula é
-- o fato que liga os dois, e carrega o que é DO PAR: status e data.
-- ---------------------------------------------------------------------
CREATE TABLE matricula (
  id              INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  aluno_id        INT                 NOT NULL REFERENCES aluno (id) ON DELETE RESTRICT,
  turma_id        INT                 NOT NULL REFERENCES turma (id) ON DELETE RESTRICT,
  status          tp_status_matricula NOT NULL DEFAULT 'MATRICULADO',
  data_matricula  TIMESTAMPTZ         NOT NULL DEFAULT now(),
  -- o mesmo aluno não entra duas vezes na mesma turma
  CONSTRAINT uq_matricula_aluno_turma UNIQUE (aluno_id, turma_id)
);
COMMENT ON TABLE matricula IS 'Vínculo aluno-turma; status MATRICULADO = vínculo ativo (ocupa vaga)';


-- ---------------------------------------------------------------------
-- 3.12 HISTÓRICO (resultado de cada matrícula: notas, frequência, situação)
-- Regra do IESB: média = 0,4 x A1 + 0,6 x A2. Quem fica abaixo de 5 faz a P3,
-- que substitui a nota menos favorável (A1 ou A2). Aprovação: média >= 5
-- e frequência >= 75%.
-- ---------------------------------------------------------------------
CREATE TABLE historico (
  id            INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- 1:1 com matrícula (UNIQUE). RESTRICT: nota é documento acadêmico;
  -- não se apaga uma matrícula que já tem histórico.
  matricula_id  INT           NOT NULL UNIQUE REFERENCES matricula (id) ON DELETE RESTRICT,
  nota_a1       dm_nota,
  nota_a2       dm_nota,
  nota_p3       dm_nota,
  frequencia    dm_percentual,
  -- COLUNA GERADA com a regra de negócio da média. Nula enquanto faltar nota.
  -- Com P3, fica a melhor entre: sem P3, P3 no lugar da A1, P3 no lugar da A2.
  media_final   NUMERIC(4,2) GENERATED ALWAYS AS (
                  CASE
                    WHEN nota_a1 IS NULL OR nota_a2 IS NULL THEN NULL
                    WHEN nota_p3 IS NULL THEN round(0.4 * nota_a1 + 0.6 * nota_a2, 2)
                    ELSE round(greatest(0.4 * nota_a1 + 0.6 * nota_a2,
                                        0.4 * nota_p3 + 0.6 * nota_a2,
                                        0.4 * nota_a1 + 0.6 * nota_p3), 2)
                  END) STORED,
  situacao      tp_situacao_historico NOT NULL DEFAULT 'CURSANDO',
  atualizado_em TIMESTAMPTZ           NOT NULL DEFAULT now(),
  -- P3 só existe depois de A1 e A2
  CONSTRAINT ck_historico_p3_depois_de_a1_a2
    CHECK (nota_p3 IS NULL OR (nota_a1 IS NOT NULL AND nota_a2 IS NOT NULL)),
  -- A situação tem de bater com média e frequência. Repare nos IS NOT NULL:
  -- num CHECK, resultado NULO conta como "passou"; sem eles, um APROVADO
  -- sem nota escaparia da regra.
  CONSTRAINT ck_historico_situacao_coerente CHECK (
    CASE situacao
      WHEN 'CURSANDO'        THEN true
      WHEN 'APROVADO'        THEN media_final IS NOT NULL AND media_final >= 5
                                  AND frequencia IS NOT NULL AND frequencia >= 75
      WHEN 'REPROVADO_NOTA'  THEN media_final IS NOT NULL AND media_final < 5
                                  AND frequencia IS NOT NULL AND frequencia >= 75
      WHEN 'REPROVADO_FALTA' THEN frequencia IS NOT NULL AND frequencia < 75
    END)
);
COMMENT ON TABLE  historico             IS 'Resultado acadêmico de cada matrícula (1:1)';
COMMENT ON COLUMN historico.media_final IS 'Coluna gerada: 0,4*A1 + 0,6*A2, com P3 substituindo a nota menos favorável';


-- =====================================================================
-- 4. GATILHOS (TRIGGERS) DE INTEGRIDADE
-- ---------------------------------------------------------------------
-- Regras que envolvem OUTRAS linhas ou OUTRAS tabelas não cabem em CHECK.
-- Para elas usamos gatilhos. As funções são SECURITY DEFINER (rodam com os
-- privilégios do dono) para que a regra valha igual para qualquer usuário,
-- mesmo um que, pelo RLS, não enxergue as outras linhas.
-- =====================================================================

-- 4.1 Pré-requisitos não podem formar ciclo (A exige B, B exige C, C exige A).
-- O CHECK da tabela só barra o ciclo de tamanho 1 (A exige A). Para os
-- maiores, subimos a árvore a partir do requisito com uma CTE recursiva: se
-- chegarmos na própria disciplina, a nova linha fecharia um ciclo.
CREATE FUNCTION fn_tg_pre_requisito_sem_ciclo()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = academico, pg_catalog, pg_temp
AS $$
DECLARE
  v_disc text;
  v_req  text;
BEGIN
  IF EXISTS (
       WITH RECURSIVE acima AS (
         SELECT pr.requisito_id AS id
           FROM pre_requisito pr
          WHERE pr.disciplina_id = NEW.requisito_id
         UNION                       -- UNION (sem ALL) descarta repetidos: garante que termina
         SELECT pr.requisito_id
           FROM pre_requisito pr
           JOIN acima a ON pr.disciplina_id = a.id
       )
       SELECT 1 FROM acima WHERE id = NEW.disciplina_id
     ) THEN
    SELECT codigo INTO v_disc FROM disciplina WHERE id = NEW.disciplina_id;
    SELECT codigo INTO v_req  FROM disciplina WHERE id = NEW.requisito_id;
    RAISE EXCEPTION 'Ciclo de pré-requisitos: % já depende (direta ou indiretamente) de %', v_req, v_disc
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_pre_requisito_sem_ciclo
  BEFORE INSERT OR UPDATE ON pre_requisito
  FOR EACH ROW EXECUTE FUNCTION fn_tg_pre_requisito_sem_ciclo();


-- 4.2 Um aluno não pode ter duas matrículas ATIVAS na mesma disciplina e no
-- mesmo período (por exemplo, em CCODM5A e CCONM5A de CCO072 ao mesmo tempo).
-- O UNIQUE (aluno_id, turma_id) não pega isso, porque são turmas diferentes.
-- Matrícula cancelada/concluída não conta: dá para cancelar e entrar em outra.
-- O "FOR NO KEY UPDATE" trava a linha do aluno: duas inserções simultâneas
-- do MESMO aluno entram em fila e a segunda já enxerga a primeira.
CREATE FUNCTION fn_tg_matricula_disciplina_unica()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = academico, pg_catalog, pg_temp
AS $$
DECLARE
  v_disciplina int;
  v_periodo    int;
BEGIN
  IF NEW.status <> 'MATRICULADO' THEN
    RETURN NEW;
  END IF;

  PERFORM 1 FROM aluno WHERE id = NEW.aluno_id FOR NO KEY UPDATE;

  SELECT disciplina_id, periodo_letivo_id
    INTO v_disciplina, v_periodo
    FROM turma WHERE id = NEW.turma_id;

  IF EXISTS (SELECT 1
               FROM matricula m
               JOIN turma t ON t.id = m.turma_id
              WHERE m.aluno_id = NEW.aluno_id
                AND m.status = 'MATRICULADO'
                AND m.id <> NEW.id
                AND t.disciplina_id = v_disciplina
                AND t.periodo_letivo_id = v_periodo) THEN
    RAISE EXCEPTION 'O aluno % já tem matrícula ativa nesta disciplina neste período', NEW.aluno_id
      USING ERRCODE = 'unique_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_matricula_disciplina_unica
  BEFORE INSERT OR UPDATE OF aluno_id, turma_id, status ON matricula
  FOR EACH ROW EXECUTE FUNCTION fn_tg_matricula_disciplina_unica();


-- 4.3 Carimbo de atualização do histórico (quando a nota muda, a data muda).
CREATE FUNCTION fn_tg_historico_atualizado_em()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = academico, pg_catalog, pg_temp
AS $$
BEGIN
  NEW.atualizado_em := now();
  RETURN NEW;
END $$;

CREATE TRIGGER trg_historico_atualizado_em
  BEFORE UPDATE ON historico
  FOR EACH ROW EXECUTE FUNCTION fn_tg_historico_atualizado_em();


-- =====================================================================
-- 5. CONFERÊNCIA
-- information_schema funciona em qualquer ferramenta (pgAdmin, CloudBeaver,
-- psql). No psql também dá para usar \dt academico.*
-- =====================================================================
SELECT table_name AS tabela,
       (SELECT count(*) FROM information_schema.columns c
         WHERE c.table_schema = t.table_schema AND c.table_name = t.table_name) AS colunas
  FROM information_schema.tables t
 WHERE table_schema = 'academico' AND table_type = 'BASE TABLE'
 ORDER BY table_name;
