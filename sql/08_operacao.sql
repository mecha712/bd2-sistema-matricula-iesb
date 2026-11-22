-- #####################################################################
-- ##  08_operacao.sql — BACKUP E RESTAURAÇÃO                           ##
-- ##  Projeto Acadêmico · Banco de Dados II (CCO072) · IESB · 2026/2   ##
-- ##  Frente: Administração e Operação                                 ##
-- #####################################################################
--
-- O backup em si é feito FORA do SQL, pelas ferramentas pg_dump,
-- pg_dumpall e pg_restore (que já vêm dentro do contêiner), digitados no
-- cmd (passo a passo no README.md, seção "Backup e restauração").
-- Este script cria a view de INVENTÁRIO, usada para PROVAR que a
-- restauração devolveu exatamente os mesmos dados.
--
-- ESTRATÉGIA DE BACKUP
--   1) pg_dumpall --globals-only  -> papéis (aluno, secretaria...) e senhas.
--      Papéis são do SERVIDOR, não do banco: o pg_dump NÃO os leva. Sem
--      eles, as políticas de RLS e os GRANTs não teriam a quem se referir
--      num servidor novo.
--   2) pg_dump -Fc (formato "custom") -> o banco iesb inteiro: estrutura,
--      dados, índices, views, funções, gatilhos, políticas de RLS, GRANTs.
--      Por que -Fc e não um .sql puro: vem compactado, permite restaurar só
--      uma tabela (pg_restore -t) e restaurar em paralelo (pg_restore -j).
--   O pg_dump é um backup LÓGICO e CONSISTENTE: ele lê tudo dentro de uma
--   única transação (snapshot), então o arquivo representa um instante
--   exato do banco, mesmo com gente usando o sistema durante a cópia.
--
-- COMANDOS (no cmd, dentro da pasta do projeto)
--   Backup:
--     docker exec bd2_projeto_db pg_dumpall -U postgres --globals-only -f /tmp/papeis.sql
--     docker exec bd2_projeto_db pg_dump -U postgres -d iesb -Fc -f /tmp/iesb.dump
--     docker cp bd2_projeto_db:/tmp/papeis.sql papeis.sql
--     docker cp bd2_projeto_db:/tmp/iesb.dump iesb.dump
--   Restauração:
--     docker cp iesb.dump bd2_projeto_db:/tmp/iesb.dump
--     docker exec bd2_projeto_db dropdb -U postgres --force iesb     (--force derruba conexões abertas)
--     docker exec bd2_projeto_db pg_restore -U postgres -d postgres --create --exit-on-error /tmp/iesb.dump
--   Servidor novo (sem os papéis): antes do pg_restore, copie o papeis.sql
--   para /tmp e rode: docker exec bd2_projeto_db psql -U postgres -d postgres -f /tmp/papeis.sql
--   O --create recria o banco com as configurações dele (search_path,
--   timezone) e o pg_restore refaz o REFRESH da materialized view no fim.
--
-- POLÍTICA SUGERIDA PARA PRODUÇÃO
--   * Diário (madrugada) com retenção de 30 dias + semanal com retenção
--     de 6 meses, cópia FORA do servidor (outro disco/nuvem).
--   * Antes e depois de cada janela de lançamento de notas, um backup extra.
--   * RPO (quanto dado se aceita perder): até 24 h com o diário. Para RPO
--     de minutos seria preciso backup FÍSICO contínuo (pg_basebackup +
--     arquivamento de WAL, permitindo recuperação até um instante: PITR).
--   * Backup só vale se a restauração for testada: a restauração é
--     conferida comparando o inventário abaixo antes e depois.
-- =====================================================================

SET search_path TO academico, public;


-- =====================================================================
-- vw_inventario — "impressão digital" do banco
-- Para cada tabela: quantas linhas e um hash md5 de TODO o conteúdo (todas
-- as linhas, em ordem de id, convertidas em texto). Se um único valor de
-- uma única nota mudar, o hash muda completamente.
-- Rodar antes do backup e depois da restauração: tem de dar IGUAL.
-- =====================================================================
CREATE OR REPLACE VIEW vw_inventario AS
SELECT tabela, linhas, assinatura
  FROM (
    SELECT 1 AS ordem, 'aluno' AS tabela, count(*) AS linhas,
           md5(string_agg(t::text, '|' ORDER BY t.id)) AS assinatura
      FROM aluno t
    UNION ALL
    SELECT 2, 'disciplina', count(*), md5(string_agg(t::text, '|' ORDER BY t.id)) FROM disciplina t
    UNION ALL
    SELECT 3, 'pre_requisito', count(*),
           md5(string_agg(t::text, '|' ORDER BY t.disciplina_id, t.requisito_id)) FROM pre_requisito t
    UNION ALL
    SELECT 4, 'turma', count(*), md5(string_agg(t::text, '|' ORDER BY t.id)) FROM turma t
    UNION ALL
    SELECT 5, 'turma_horario', count(*),
           md5(string_agg(t::text, '|' ORDER BY t.turma_id, t.dia_semana, t.hora_inicio)) FROM turma_horario t
    UNION ALL
    SELECT 6, 'matricula', count(*), md5(string_agg(t::text, '|' ORDER BY t.id)) FROM matricula t
    UNION ALL
    SELECT 7, 'historico', count(*), md5(string_agg(t::text, '|' ORDER BY t.id)) FROM historico t
    UNION ALL
    SELECT 8, 'mv_indicadores_disciplina', count(*), NULL FROM mv_indicadores_disciplina
  ) x
 ORDER BY ordem;

COMMENT ON VIEW vw_inventario IS 'Contagem e hash md5 do conteúdo de cada tabela: compara o banco antes do backup e depois da restauração';

GRANT SELECT ON vw_inventario TO coordenacao;

SELECT * FROM vw_inventario;
