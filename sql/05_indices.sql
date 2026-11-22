-- #####################################################################
-- ##  05_indices.sql — ÍNDICES COM EXPLAIN ANTES E DEPOIS              ##
-- ##  Projeto Acadêmico · Banco de Dados II (CCO072) · IESB · 2026/2   ##
-- ##  Frente: Modelagem Física e Desempenho                            ##
-- #####################################################################
--
-- COMO LER
--   Para cada índice: a consulta que ele atende, o EXPLAIN (ANALYZE,
--   BUFFERS) SEM o índice, a criação, e o mesmo EXPLAIN COM o índice.
--   O script começa apagando os índices do projeto, então pode ser rodado
--   de novo ao vivo para mostrar o ganho na hora.
--   Os números medidos ficam em evidencias/EXPLAIN_ANALYZE.md.
--
-- O QUE OLHAR NO EXPLAIN
--   * Seq Scan      = leu a tabela inteira.
--   * Index Scan / Index Only Scan / Bitmap Index Scan = usou índice.
--   * Execution Time = tempo real da execução.
--   * Buffers: shared hit=N = quantas páginas de 8 KB foram lidas
--     (hit = já estavam na memória; read = vieram do disco). Menos páginas,
--     menos trabalho: é a medida mais estável, não varia com a máquina.
--
-- ÍNDICES QUE JÁ EXISTEM SEM PRECISAR CRIAR
--   O PostgreSQL cria sozinho um índice B-tree para cada PRIMARY KEY e
--   UNIQUE. Alguns já atendem consultas importantes:
--   * uq_matricula_aluno_turma (aluno_id, turma_id): atende "matrículas
--     de um aluno", porque aluno_id é a PRIMEIRA coluna. Por isso NÃO criamos
--     índice só em aluno_id: seria redundante.
--   * historico.matricula_id (UNIQUE): atende a junção matrícula -> histórico.
--   * aluno.matricula, aluno.cpf, aluno.login_bd (UNIQUE): busca por RA,
--     por CPF e o filtro do RLS (script 07).
--   ATENÇÃO: o PostgreSQL NÃO cria índice para FOREIGN KEY sozinho (o MySQL
--   cria). Por isso matricula.turma_id precisa do índice 2 abaixo.
--
-- CUSTO DE TODO ÍNDICE: ocupa disco e deixa INSERT/UPDATE um pouco mais
--   lentos (o índice também é atualizado). Por isso cada um aqui tem uma
--   consulta real que justifica a sua existência.
-- =====================================================================

SET search_path TO academico, public;

-- recomeça sem os índices do projeto (para o "antes" ser honesto)
DROP INDEX IF EXISTS ix_matricula_turma_ativa;
DROP INDEX IF EXISTS ix_matricula_turma;
DROP INDEX IF EXISTS ix_historico_risco_falta;
DROP INDEX IF EXISTS ix_aluno_nome_trgm;
DROP INDEX IF EXISTS ix_matricula_data_brin;
ANALYZE matricula;
ANALYZE historico;
ANALYZE aluno;


-- =====================================================================
-- ÍNDICE 1 (PARCIAL) — vagas ocupadas de uma turma
-- CONSULTA: "quantas matrículas ATIVAS a turma tem?" É o coração da
--   disputa pela vaga: a função de matrícula (script 06) e a vw_vagas fazem
--   essa conta a cada matrícula.
-- POR QUE PARCIAL: só as matrículas com status MATRICULADO ocupam vaga, e
--   elas são só as do semestre atual (~17% da tabela). O WHERE do índice
--   deixa de fora as matrículas encerradas: o índice fica ~6x menor, cabe
--   inteiro na memória e a contagem vira Index Only Scan (nem toca na tabela).
-- REGRA: o planejador só usa um índice parcial se o WHERE da consulta
--   implicar o WHERE do índice (aqui: status = 'MATRICULADO').
-- REPARE NO "ANTES": às vezes o otimizador usa o índice composto
--   uq_matricula_aluno_turma (aluno_id, turma_id), mas como turma_id é a
--   SEGUNDA coluna ele precisa varrer o índice INTEIRO. A ordem das colunas
--   num índice composto importa: ele serve para aluno_id, não para turma_id.
-- Turma 2286 = CCO072 / CCONM5B, a turma da demonstração de concorrência.
-- =====================================================================
-- ANTES
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM matricula WHERE turma_id = 2286 AND status = 'MATRICULADO';

CREATE INDEX ix_matricula_turma_ativa
    ON matricula (turma_id)
 WHERE status = 'MATRICULADO';
ANALYZE matricula;

-- DEPOIS
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM matricula WHERE turma_id = 2286 AND status = 'MATRICULADO';


-- =====================================================================
-- ÍNDICE 2 (B-TREE COMUM) — chave estrangeira matricula.turma_id
-- CONSULTA: "diário de classe" de uma turma já encerrada (todas as
--   matrículas, qualquer status), com nome e nota. O índice parcial acima
--   não serve aqui, porque a consulta não filtra status.
-- TAMBÉM ACELERA a própria integridade: ao apagar uma turma, o
--   ON DELETE RESTRICT procura matrículas que apontem para ela. Sem índice
--   na FK, cada uma dessas checagens faz Seq Scan em toda a tabela. No
--   EXPLAIN do DELETE isso aparece na linha
--   "Trigger for constraint matricula_turma_id_fkey: time=...".
--   (O DELETE roda dentro de BEGIN ... ROLLBACK: mede e desfaz.)
-- Turma 1579 = CCO072 / CCONM5A de 2025/2 (40 alunos).
-- Turma 2386 = CCOVM7A, turma vazia de 2026/2 (pode ser apagada).
-- =====================================================================
-- ANTES
EXPLAIN (ANALYZE, BUFFERS)
SELECT a.matricula, a.nome, h.media_final, h.situacao
  FROM matricula m
  JOIN aluno a     ON a.id = m.aluno_id
  JOIN historico h ON h.matricula_id = m.id
 WHERE m.turma_id = 1579
 ORDER BY a.nome;

BEGIN;
EXPLAIN (ANALYZE, BUFFERS) DELETE FROM turma WHERE id = 2386;
ROLLBACK;

CREATE INDEX ix_matricula_turma ON matricula (turma_id);
ANALYZE matricula;

-- DEPOIS
EXPLAIN (ANALYZE, BUFFERS)
SELECT a.matricula, a.nome, h.media_final, h.situacao
  FROM matricula m
  JOIN aluno a     ON a.id = m.aluno_id
  JOIN historico h ON h.matricula_id = m.id
 WHERE m.turma_id = 1579
 ORDER BY a.nome;

BEGIN;
EXPLAIN (ANALYZE, BUFFERS) DELETE FROM turma WHERE id = 2386;
ROLLBACK;


-- =====================================================================
-- ÍNDICE 3 (PARCIAL) — alunos em risco de reprovar por falta, agora
-- CONSULTA: relatório da coordenação com quem ainda está CURSANDO e já
--   está abaixo de 75% de frequência (o limite de aprovação).
-- POR QUE PARCIAL: dos ~88 mil históricos, só ~1,3 mil satisfazem a
--   condição. Os semestres encerrados nunca mais interessam a esse relatório
--   e ficam fora do índice. Índice minúsculo, consulta direta.
-- POR QUE A COLUNA frequencia: o relatório ordena por frequência (os mais
--   graves primeiro); o índice já entrega as linhas nessa ordem.
-- =====================================================================
-- ANTES
EXPLAIN (ANALYZE, BUFFERS)
SELECT h.matricula_id, h.frequencia
  FROM historico h
 WHERE h.situacao = 'CURSANDO' AND h.frequencia < 75
 ORDER BY h.frequencia;

CREATE INDEX ix_historico_risco_falta
    ON historico (frequencia)
 WHERE situacao = 'CURSANDO' AND frequencia < 75;
ANALYZE historico;

-- DEPOIS
EXPLAIN (ANALYZE, BUFFERS)
SELECT h.matricula_id, h.frequencia
  FROM historico h
 WHERE h.situacao = 'CURSANDO' AND h.frequencia < 75
 ORDER BY h.frequencia;


-- =====================================================================
-- ÍNDICE 4 (GIN COM TRIGRAMAS) — busca de aluno por parte do nome
-- CONSULTA: a secretaria digita um trecho do nome ("souza peixoto") e quer
--   o aluno que tenha isso EM QUALQUER PARTE do nome, sem diferenciar
--   maiúscula de minúscula (ILIKE).
-- POR QUE NÃO B-TREE: um B-tree só ajuda quando o começo do texto é
--   conhecido (LIKE 'Ana%'). Com '%souza peixoto%' o começo é qualquer coisa.
--   O pg_trgm quebra o nome em trigramas ("sou", "ouz", "uza"...) e o
--   índice GIN acha as linhas que contêm todos os trigramas da busca.
-- O OTIMIZADOR DECIDE POR CUSTO: para um trecho muito comum (ex.: 'silva',
--   que aparece em ~4% dos nomes) ele prefere ler a tabela inteira, que é
--   pequena (94 páginas). O índice entra quando a busca é seletiva, que é o
--   caso real da secretaria procurando UMA pessoa. Isso não é erro: é o
--   planejador comparando o custo dos dois caminhos.
-- =====================================================================
-- ANTES
EXPLAIN (ANALYZE, BUFFERS)
SELECT matricula, nome FROM aluno WHERE nome ILIKE '%souza peixoto%';

CREATE INDEX ix_aluno_nome_trgm ON aluno USING gin (nome gin_trgm_ops);
ANALYZE aluno;

-- DEPOIS
EXPLAIN (ANALYZE, BUFFERS)
SELECT matricula, nome FROM aluno WHERE nome ILIKE '%souza peixoto%';


-- =====================================================================
-- ÍNDICE 5 (BRIN) — matrículas feitas num intervalo de datas
-- CONSULTA: "quantas matrículas entraram na semana de 13 a 19 de julho?"
--   (acompanhamento da janela de matrícula).
-- POR QUE BRIN: as matrículas são gravadas em ordem cronológica, então a
--   data cresce junto com a posição física na tabela (pg_stats mostra
--   correlation = 1). O BRIN guarda só o menor e o maior valor de cada
--   faixa de páginas: ocupa 24 kB (um B-tree na mesma coluna teria ~2 MB) e
--   mesmo assim descarta quase todas as faixas.
-- pages_per_range = 8: cada resumo cobre 8 páginas (o padrão é 128). Faixa
--   menor = resumo mais preciso, menos linhas para reconferir; com 128, a
--   faixa da semana pedida "arrastaria" muitas linhas de fora.
-- LIMITAÇÃO: só funciona bem quando há essa correlação física; numa coluna
--   embaralhada (ex.: nome), o BRIN não serve.
-- =====================================================================
-- ANTES
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM matricula
 WHERE data_matricula >= '2026-07-13' AND data_matricula < '2026-07-20';

CREATE INDEX ix_matricula_data_brin ON matricula USING brin (data_matricula)
  WITH (pages_per_range = 8);
ANALYZE matricula;

-- DEPOIS
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM matricula
 WHERE data_matricula >= '2026-07-13' AND data_matricula < '2026-07-20';


-- =====================================================================
-- TAMANHO DOS ÍNDICES (repare no parcial e no BRIN)
-- =====================================================================
SELECT c.relname                               AS indice,
       t.relname                               AS tabela,
       am.amname                               AS tipo,
       pg_size_pretty(pg_relation_size(c.oid)) AS tamanho
  FROM pg_index i
  JOIN pg_class c ON c.oid = i.indexrelid
  JOIN pg_class t ON t.oid = i.indrelid
  JOIN pg_am am   ON am.oid = c.relam
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'academico'
   AND t.relname IN ('matricula', 'historico', 'aluno')
 ORDER BY t.relname, pg_relation_size(c.oid) DESC;
