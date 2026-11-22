-- #####################################################################
-- ##  07_seguranca.sql — PAPÉIS, GRANT/REVOKE E ROW-LEVEL SECURITY     ##
-- ##  Projeto Acadêmico · Banco de Dados II (CCO072) · IESB · 2026/2   ##
-- ##  Frente: Administração e Operação                                 ##
-- #####################################################################
--
-- DUAS CAMADAS DE PROTEÇÃO
--   1) GRANT/REVOKE decide O QUE cada papel pode fazer em cada objeto
--      (ler, inserir, alterar...). É controle por TABELA/COLUNA.
--   2) ROW-LEVEL SECURITY (RLS) decide QUAIS LINHAS cada papel enxerga ou
--      altera. É controle por LINHA. Requisito do projeto: um aluno NÃO
--      pode ver o histórico de outro aluno.
--
-- PAPÉIS (roles)
--   Papéis de GRUPO (NOLOGIN, ninguém entra com eles; servem para agrupar
--   permissões): aluno, secretaria, coordenacao.
--   Papéis de LOGIN para a demonstração (cada um é membro de um grupo e
--   herda as permissões dele):
--     aluno_2024200015  Leonardo  (CCO, cursando BD II)
--     aluno_2024200005  Enzo      (CCO, atrasado por reprovação)
--     secretaria_demo
--     coordenacao_demo
--   Senha de todos: iesb2026 (apenas para a demonstração).
--   Em produção, cada aluno teria o seu papel de login (ou a aplicação
--   faria a autenticação); aqui criamos dois para mostrar o RLS.
--
-- QUEM PODE O QUÊ
--   | objeto                      | aluno            | secretaria             | coordenacao          |
--   |-----------------------------|------------------|------------------------|----------------------|
--   | catálogo (curso, disciplina,| ler              | ler                    | ler; criar/alterar   |
--   |  turma, horário, sala...)   |                  | (alterar vagas)        | turmas e horários    |
--   | aluno, matrícula, histórico | ler SÓ O SEU     | ler e alterar TUDO     | ler tudo             |
--   |                             | (RLS)            | (matricular, lançar)   |                      |
--   | vw_oferta, vw_vagas         | ler              | ler                    | ler                  |
--   | vw_historico                | ler (só o seu)   | ler                    | ler                  |
--   | mv_indicadores_disciplina   | -                | ler                    | ler e atualizar      |
--   | DELETE em qualquer tabela   | -                | -                      | -                    |
--   Ninguém além do dono (postgres) apaga dados: nota é documento.
-- =====================================================================

SET search_path TO academico, public;


-- =====================================================================
-- 1. PAPÉIS (são do SERVIDOR, não do banco: valem para todos os bancos).
-- O bloco DO só cria se ainda não existir, para o script poder rodar de novo.
-- =====================================================================
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES ('aluno'), ('secretaria'), ('coordenacao')) AS v(nome) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r.nome) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN', r.nome);
    END IF;
  END LOOP;

  FOR r IN SELECT * FROM (VALUES ('aluno_2024200015', 'aluno'),
                                 ('aluno_2024200005', 'aluno'),
                                 ('secretaria_demo',  'secretaria'),
                                 ('coordenacao_demo', 'coordenacao')) AS v(login, grupo) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r.login) THEN
      EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', r.login, 'iesb2026');
    END IF;
    EXECUTE format('GRANT %I TO %I', r.grupo, r.login);
  END LOOP;
END $$;

COMMENT ON ROLE aluno       IS 'Grupo dos alunos: lê o catálogo e SÓ os próprios dados (RLS)';
COMMENT ON ROLE secretaria  IS 'Grupo da secretaria acadêmica: matricula e lança notas';
COMMENT ON ROLE coordenacao IS 'Grupo da coordenação: lê tudo, gerencia oferta e indicadores';

-- liga cada aluno de demonstração ao seu papel de login (ponte usada pelo RLS)
UPDATE aluno SET login_bd = 'aluno_' || matricula
 WHERE matricula IN ('2024200015', '2024200005');


-- =====================================================================
-- 2. GRANT / REVOKE
-- Princípio do MENOR PRIVILÉGIO: primeiro tira tudo de PUBLIC (o "todo
-- mundo" do PostgreSQL), depois dá a cada papel só o que ele precisa.
-- =====================================================================
-- (current_database() em vez do nome fixo: o script roda em qualquer banco)
DO $$
BEGIN
  EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO aluno, secretaria, coordenacao', current_database());
END $$;

REVOKE ALL ON SCHEMA academico FROM PUBLIC;
GRANT USAGE ON SCHEMA academico TO aluno, secretaria, coordenacao;

REVOKE ALL ON ALL TABLES IN SCHEMA academico FROM PUBLIC;

-- catálogo acadêmico: leitura para todos os papéis
GRANT SELECT ON curso, curriculo, curriculo_disciplina, disciplina, pre_requisito,
                periodo_letivo, sala, turma, turma_horario
   TO aluno, secretaria, coordenacao;

-- views
GRANT SELECT ON vw_oferta, vw_vagas, vw_historico TO aluno, secretaria, coordenacao;
GRANT SELECT ON mv_indicadores_disciplina TO secretaria, coordenacao;

-- dados pessoais: o GRANT libera a TABELA; o RLS (seção 3) filtra as LINHAS
GRANT SELECT ON aluno, matricula, historico TO aluno, secretaria, coordenacao;

-- secretaria: cadastra alunos, matricula e lança notas (sem DELETE)
GRANT INSERT, UPDATE ON aluno, matricula, historico TO secretaria;
-- UPDATE só na coluna vagas da turma. Também é o que permite o
-- SELECT ... FOR UPDATE da fn_matricular (travar exige privilégio de UPDATE).
GRANT UPDATE (vagas) ON turma TO secretaria;

-- coordenação: monta a oferta do semestre
GRANT INSERT, UPDATE ON turma, turma_horario TO coordenacao;

-- funções: só quem precisa executa
REVOKE EXECUTE ON FUNCTION fn_matricular(int, int, numeric)              FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION fn_matricular_sem_controle(int, int, numeric) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION fn_atualizar_indicadores()                    FROM PUBLIC;
REVOKE EXECUTE ON PROCEDURE pr_preparar_demo_vaga()                      FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_matricular(int, int, numeric) TO secretaria;
GRANT  EXECUTE ON FUNCTION fn_atualizar_indicadores()       TO secretaria, coordenacao;


-- =====================================================================
-- 3. ROW-LEVEL SECURITY
-- Com o RLS ligado, uma linha só aparece se ALGUMA política permitir.
-- Sem política nenhuma para o papel, ele não vê NADA (negação por padrão).
-- O RLS não dá erro: ele simplesmente filtra. O aluno que tenta ler o
-- histórico de outro recebe zero linhas.
--
-- Quem ignora o RLS: superusuários e o dono da tabela (postgres). Os
-- papéis da aplicação NUNCA devem ser superusuário nem donos das tabelas.
--
-- A identidade vem de current_user (o papel com que a sessão entrou ou
-- assumiu via SET ROLE) comparado com aluno.login_bd. Não dá para falsificar
-- de dentro da sessão: para "virar" outro aluno seria preciso a senha dele.
-- =====================================================================
ALTER TABLE aluno     ENABLE ROW LEVEL SECURITY;
ALTER TABLE matricula ENABLE ROW LEVEL SECURITY;
ALTER TABLE historico ENABLE ROW LEVEL SECURITY;

SET client_min_messages TO warning;     -- silencia os avisos "não existe" dos DROP abaixo
DROP POLICY IF EXISTS pol_aluno_proprio       ON aluno;
DROP POLICY IF EXISTS pol_aluno_secretaria    ON aluno;
DROP POLICY IF EXISTS pol_aluno_coordenacao   ON aluno;
DROP POLICY IF EXISTS pol_matricula_propria     ON matricula;
DROP POLICY IF EXISTS pol_matricula_secretaria  ON matricula;
DROP POLICY IF EXISTS pol_matricula_coordenacao ON matricula;
DROP POLICY IF EXISTS pol_historico_proprio     ON historico;
DROP POLICY IF EXISTS pol_historico_secretaria  ON historico;
DROP POLICY IF EXISTS pol_historico_coordenacao ON historico;
RESET client_min_messages;

-- ---- ALUNO: cada um vê só a si mesmo, as suas matrículas e o seu histórico
CREATE POLICY pol_aluno_proprio ON aluno
  FOR SELECT TO aluno
  USING (login_bd = current_user);

CREATE POLICY pol_matricula_propria ON matricula
  FOR SELECT TO aluno
  USING (aluno_id IN (SELECT a.id FROM aluno a WHERE a.login_bd = current_user));

CREATE POLICY pol_historico_proprio ON historico
  FOR SELECT TO aluno
  USING (matricula_id IN (SELECT m.id
                            FROM matricula m
                            JOIN aluno a ON a.id = m.aluno_id
                           WHERE a.login_bd = current_user));

-- ---- SECRETARIA: vê e altera todas as linhas (FOR ALL = SELECT/INSERT/UPDATE/DELETE;
--      o DELETE continua barrado pelo GRANT, que não foi dado)
CREATE POLICY pol_aluno_secretaria     ON aluno     FOR ALL TO secretaria USING (true) WITH CHECK (true);
CREATE POLICY pol_matricula_secretaria ON matricula FOR ALL TO secretaria USING (true) WITH CHECK (true);
CREATE POLICY pol_historico_secretaria ON historico FOR ALL TO secretaria USING (true) WITH CHECK (true);

-- ---- COORDENAÇÃO: vê todas as linhas, não altera
CREATE POLICY pol_aluno_coordenacao     ON aluno     FOR SELECT TO coordenacao USING (true);
CREATE POLICY pol_matricula_coordenacao ON matricula FOR SELECT TO coordenacao USING (true);
CREATE POLICY pol_historico_coordenacao ON historico FOR SELECT TO coordenacao USING (true);


-- =====================================================================
-- 4. CONFERÊNCIA
-- =====================================================================
-- as políticas em vigor
SELECT tablename AS tabela, policyname AS politica, roles AS papeis, cmd AS comando, qual AS condicao
  FROM pg_policies
 WHERE schemaname = 'academico'
 ORDER BY tablename, policyname;

-- quem é membro de quê
SELECT r.rolname AS login, g.rolname AS grupo
  FROM pg_auth_members am
  JOIN pg_roles r ON r.oid = am.member
  JOIN pg_roles g ON g.oid = am.roleid
 WHERE g.rolname IN ('aluno', 'secretaria', 'coordenacao')
 ORDER BY g.rolname, r.rolname;

-- a prova: o mesmo SELECT, três papéis diferentes
SET ROLE aluno_2024200015;
SELECT current_user AS quem, count(*) AS historicos_visiveis FROM historico;
RESET ROLE;

SET ROLE secretaria_demo;
SELECT current_user AS quem, count(*) AS historicos_visiveis FROM historico;
RESET ROLE;
