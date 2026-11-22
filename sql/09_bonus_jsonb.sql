-- #####################################################################
-- ##  09_bonus_jsonb.sql — BÔNUS: AUDITORIA EM JSONB COM ÍNDICE GIN    ##
-- ##  Projeto Acadêmico · Banco de Dados II (CCO072) · IESB · 2026/2   ##
-- #####################################################################
--
-- A IDEIA
--   Toda mudança no histórico (lançamento, correção ou exclusão de nota) é
--   registrada automaticamente num LOG DE AUDITORIA: quem, quando, o que
--   era antes e o que ficou depois. "Antes" e "depois" são a linha inteira
--   do histórico em JSONB.
--
-- POR QUE JSONB AQUI (e não colunas)
--   * O log é um RETRATO da linha naquele instante. Se amanhã o histórico
--     ganhar uma coluna nova, o log continua funcionando sem ALTER TABLE.
--   * O mesmo gatilho serve para qualquer tabela (estrutura variável).
--   * O log só é gravado e consultado, nunca atualizado: não há anomalia de
--     atualização a evitar. Por isso não fere a normalização do modelo
--     principal: os dados "oficiais" continuam nas tabelas normalizadas.
--   JSONB (e não JSON): é gravado já decomposto em binário, aceita índice e
--   tem operadores de busca como @> ("contém").
--
-- POR QUE ÍNDICE GIN
--   Um B-tree indexa um valor por linha. O GIN (índice invertido) indexa
--   CADA chave/valor de dentro do documento, apontando para as linhas que o
--   contêm: é o que torna rápida a pergunta "quais registros contêm
--   {"matricula_id": 4321}?" sem abrir os 88 mil documentos.
--   jsonb_path_ops: versão do GIN menor e mais rápida para @>; em troca,
--   não atende os operadores de existência de chave (?, ?|, ?&).
-- =====================================================================

SET search_path TO academico, public;

DROP TABLE IF EXISTS log_auditoria;
CREATE TABLE log_auditoria (
  id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- BIGINT: log cresce sem parar
  momento   TIMESTAMPTZ NOT NULL DEFAULT now(),
  usuario   TEXT        NOT NULL,
  tabela    TEXT        NOT NULL,
  operacao  TEXT        NOT NULL CHECK (operacao IN ('INSERT', 'UPDATE', 'DELETE')),
  dados     JSONB       NOT NULL
);
COMMENT ON TABLE log_auditoria IS 'Bônus: log de auditoria do histórico em JSONB (antes/depois), indexado com GIN';


-- =====================================================================
-- 1. O GATILHO DE AUDITORIA
-- SECURITY DEFINER: quem grava no log é o dono da função. A secretaria
-- altera notas, mas NÃO tem permissão de escrever no log diretamente:
-- não consegue apagar nem forjar o rastro.
-- Usuário registrado: o papel assumido com SET ROLE, se houver; senão, o
-- usuário que fez login (session_user). Dentro de uma função SECURITY
-- DEFINER, current_user seria o dono, por isso não serve aqui.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_tg_auditoria()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = academico, pg_catalog, pg_temp
AS $$
DECLARE
  v_antes     jsonb;
  v_depois    jsonb;
  v_alterados jsonb;
  v_usuario   text := CASE WHEN current_setting('role') IN ('none', '') THEN session_user::text
                           ELSE current_setting('role') END;
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN v_antes  := to_jsonb(OLD); END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN v_depois := to_jsonb(NEW); END IF;

  IF TG_OP = 'UPDATE' THEN
    -- lista as colunas que realmente mudaram (o carimbo de data não conta)
    SELECT jsonb_agg(d.key ORDER BY d.key)
      INTO v_alterados
      FROM jsonb_each(v_depois) AS d
     WHERE d.value IS DISTINCT FROM v_antes -> d.key
       AND d.key <> 'atualizado_em';
    IF v_alterados IS NULL THEN
      RETURN NULL;                        -- UPDATE que não mudou nada: não registra
    END IF;
  END IF;

  INSERT INTO log_auditoria (usuario, tabela, operacao, dados)
  VALUES (v_usuario, TG_TABLE_NAME, TG_OP,
          jsonb_build_object('antes', v_antes, 'depois', v_depois, 'alterados', v_alterados));
  RETURN NULL;                            -- gatilho AFTER: o retorno é ignorado
END $$;


-- =====================================================================
-- 2. CARGA RETROATIVA: os lançamentos de nota que já existem viram
-- registros de INSERT no log (um por histórico, na data do lançamento).
-- Assim o log nasce com ~88 mil documentos, volume em que o índice faz
-- diferença. O usuário 'carga_inicial' deixa claro que vieram da importação.
-- =====================================================================
INSERT INTO log_auditoria (momento, usuario, tabela, operacao, dados)
SELECT h.atualizado_em, 'carga_inicial', 'historico', 'INSERT',
       jsonb_build_object('antes', NULL, 'depois', to_jsonb(h), 'alterados', NULL)
  FROM historico h
 ORDER BY h.atualizado_em, h.id;

-- a partir daqui, toda mudança no histórico é registrada sozinha
DROP TRIGGER IF EXISTS trg_auditoria_historico ON historico;
CREATE TRIGGER trg_auditoria_historico
  AFTER INSERT OR UPDATE OR DELETE ON historico
  FOR EACH ROW EXECUTE FUNCTION fn_tg_auditoria();

ANALYZE log_auditoria;


-- =====================================================================
-- 3. ÍNDICE GIN COM EXPLAIN ANTES E DEPOIS
-- Pergunta: "tudo o que aconteceu com as notas da matrícula 4321"
-- =====================================================================
-- ANTES
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, momento, usuario, operacao
  FROM log_auditoria
 WHERE dados @> '{"depois": {"matricula_id": 4321}}';

CREATE INDEX ix_log_auditoria_dados ON log_auditoria USING gin (dados jsonb_path_ops);
ANALYZE log_auditoria;

-- DEPOIS
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, momento, usuario, operacao
  FROM log_auditoria
 WHERE dados @> '{"depois": {"matricula_id": 4321}}';


-- =====================================================================
-- 4. PERMISSÕES: a coordenação audita (lê); ninguém escreve direto.
-- =====================================================================
REVOKE ALL ON log_auditoria FROM PUBLIC;
GRANT SELECT ON log_auditoria TO coordenacao;


-- =====================================================================
-- 5. EXEMPLOS DE CONSULTA EM JSONB
--   ->  devolve JSONB      ->> devolve TEXTO      @> "contém"
-- =====================================================================
-- 5.1 Linha do tempo das notas de uma matrícula
SELECT momento, usuario, operacao,
       dados -> 'depois' ->> 'nota_a1'     AS a1,
       dados -> 'depois' ->> 'nota_a2'     AS a2,
       dados -> 'depois' ->> 'nota_p3'     AS p3,
       dados -> 'depois' ->> 'media_final' AS media,
       dados -> 'depois' ->> 'situacao'    AS situacao
  FROM log_auditoria
 WHERE dados @> '{"depois": {"matricula_id": 4321}}'
 ORDER BY momento;

-- 5.2 Quantos lançamentos terminaram em reprovação por falta (contenção também usa o GIN)
SELECT count(*) AS lancamentos_reprovado_falta
  FROM log_auditoria
 WHERE dados @> '{"depois": {"situacao": "REPROVADO_FALTA"}}';

-- 5.3 Demonstração ao vivo: a secretaria corrige uma nota e o log registra
--     sozinho quem, quando, antes, depois e quais colunas mudaram.
--     (dentro de BEGIN ... ROLLBACK para não alterar o banco)
BEGIN;
SET LOCAL ROLE secretaria_demo;
UPDATE historico SET nota_a1 = nota_a1 + 0.5
 WHERE matricula_id = (SELECT max(matricula_id) FROM historico WHERE situacao = 'CURSANDO' AND nota_a1 <= 9.5);
RESET ROLE;
SELECT momento, usuario, operacao,
       dados -> 'alterados'                 AS colunas_alteradas,
       dados -> 'antes'  ->> 'nota_a1'      AS a1_antes,
       dados -> 'depois' ->> 'nota_a1'      AS a1_depois
  FROM log_auditoria
 ORDER BY id DESC
 LIMIT 1;
ROLLBACK;
