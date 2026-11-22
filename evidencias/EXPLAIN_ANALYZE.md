# Evidências de EXPLAIN (ANALYZE, BUFFERS) — antes e depois de cada índice

Projeto Acadêmico · Banco de Dados II (CCO072) · IESB · 2026/2 · frente **Modelagem Física e Desempenho**

- **Gerado em:** 20/11/2026, PostgreSQL 16.15 (ambiente de testes). No contêiner oficial (PostgreSQL 17) os **planos** são os mesmos; os **tempos** variam com a máquina.
- **Volume:** 88.365 matrículas, 88.365 históricos, 3.804 alunos, 88.365 registros de auditoria.
- **Método:** para cada índice, a consulta roda 2 vezes para aquecer o cache e depois 7 vezes com `EXPLAIN (ANALYZE, BUFFERS)`; o tempo é a **mediana** das 7. "Páginas" = blocos de 8 kB lidos pelo plano (`shared hit + read`): é a medida que não depende da máquina.
- **Como o "antes" foi obtido:** o índice é apagado, a consulta é medida, o índice é recriado com a mesma definição e a consulta é medida de novo (é o que o script `sql/05_indices.sql` faz).

## Resumo

| # | Índice | Tipo | Plano ANTES | Plano DEPOIS | Tempo antes → depois | Páginas antes → depois | Ganho | Tamanho |
|---|---|---|---|---|---|---|---|---|
| 1 | `ix_matricula_turma_ativa` | B-tree PARCIAL | Seq Scan (matricula) | Index Only Scan (ix_matricula_turma_ativa) | 4,564 ms → 0,075 ms | 563 → 3 | **61×** | 120 kB |
| 2 | `ix_matricula_turma` | B-tree (chave estrangeira) | Seq Scan (aluno); Seq Scan (matricula); Index Scan (historico_matricula_id_key) | Seq Scan (aluno); Index Scan (ix_matricula_turma); Index Scan (historico_matricula_id_key) | 6,873 ms → 1,062 ms | 780 → 250 | **6,5×** | 648 kB |
| 2b | `ix_matricula_turma` (checagem da FK no DELETE) | | gatilho da FK faz Seq Scan | gatilho da FK usa o índice | 7,141 ms → 0,378 ms | | **19×** | |
| 3 | `ix_historico_risco_falta` | B-tree PARCIAL | Seq Scan (historico) | Bitmap Heap Scan (historico); Bitmap Index Scan (ix_historico_risco_falta) | 12,904 ms → 0,948 ms | 898 → 133 | **14×** | 48 kB |
| 4 | `ix_aluno_nome_trgm` | GIN (trigramas, pg_trgm) | Seq Scan (aluno) | Bitmap Heap Scan (aluno); Bitmap Index Scan (ix_aluno_nome_trgm) | 2,959 ms → 0,303 ms | 94 → 26 | **9,8×** | 248 kB |
| 5 | `ix_matricula_data_brin` | BRIN (pages_per_range = 8) | Seq Scan (matricula) | Bitmap Heap Scan (matricula); Bitmap Index Scan (ix_matricula_data_brin) | 6,809 ms → 0,905 ms | 563 → 41 | **7,5×** | 24 kB |
| 6 | `ix_log_auditoria_dados` | GIN jsonb_path_ops (bônus) | Seq Scan (log_auditoria) | Bitmap Heap Scan (log_auditoria); Bitmap Index Scan (ix_log_auditoria_dados) | 29,652 ms → 0,071 ms | 4319 → 5 | **418×** | 12 MB |

**Índice parcial x comum:** o parcial `ix_matricula_turma_ativa` ocupa **120 kB**, contra **648 kB** do índice comum na mesma coluna (`ix_matricula_turma`), porque só guarda as matrículas ativas. E responde a contagem de vagas com *Index Only Scan* (nem toca na tabela).

**Índices que NÃO foram criados (e por quê):** `matricula(aluno_id)` — já coberto pelo UNIQUE `(aluno_id, turma_id)`, cuja primeira coluna é `aluno_id`; `historico(matricula_id)` — já é UNIQUE; `aluno(matricula)`, `aluno(cpf)`, `aluno(login_bd)` — já são UNIQUE. PRIMARY KEY e UNIQUE criam índice B-tree automaticamente; FOREIGN KEY **não** (por isso o índice 2).

---

## 1. `ix_matricula_turma_ativa` — B-tree PARCIAL

**Pergunta que o índice atende:** Quantas vagas ativas a turma da disputa (2286 = CCO072/CCONM5B) tem ocupadas? É a conta feita a cada matrícula.

```sql
CREATE INDEX ix_matricula_turma_ativa ON academico.matricula USING btree (turma_id) WHERE (status = 'MATRICULADO'::tp_status_matricula);
```

**Consulta medida:**

```sql
SELECT count(*) FROM matricula WHERE turma_id = 2286 AND status = 'MATRICULADO';
```

**ANTES — Seq Scan (matricula) — 4,564 ms (mediana), 563 páginas**

```
Aggregate  (cost=1888.49..1888.50 rows=1 width=8) (actual time=5.575..5.576 rows=1 loops=1)
  Buffers: shared hit=563
  ->  Seq Scan on matricula  (cost=0.00..1888.47 rows=5 width=0) (actual time=4.703..5.562 rows=19 loops=1)
        Filter: ((turma_id = 2286) AND (status = 'MATRICULADO'::tp_status_matricula))
        Rows Removed by Filter: 88346
        Buffers: shared hit=563
Planning:
  Buffers: shared hit=107
Planning Time: 0.569 ms
Execution Time: 5.626 ms
```

**DEPOIS — Index Only Scan (ix_matricula_turma_ativa) — 0,075 ms (mediana), 3 páginas**

```
Aggregate  (cost=4.38..4.39 rows=1 width=8) (actual time=0.038..0.039 rows=1 loops=1)
  Buffers: shared hit=3
  ->  Index Only Scan using ix_matricula_turma_ativa on matricula  (cost=0.29..4.37 rows=5 width=0) (actual time=0.028..0.030 rows=19 loops=1)
        Index Cond: (turma_id = 2286)
        Heap Fetches: 0
        Buffers: shared hit=3
Planning:
  Buffers: shared hit=120
Planning Time: 0.498 ms
Execution Time: 0.090 ms
```

**Ganho medido:** 61× mais rápido; de 563 para 3 páginas lidas.

**Leitura do plano:** Sem índice próprio em `turma_id`, o otimizador leu a tabela inteira (Seq Scan). Com o índice parcial, a contagem vira *Index Only Scan* com `Heap Fetches: 0`: a resposta sai do índice, sem tocar na tabela.

---

## 2. `ix_matricula_turma` — B-tree (chave estrangeira)

**Pergunta que o índice atende:** Diário de classe da turma 1579 (CCO072/CCONM5A de 2025/2): alunos, médias e situação.

```sql
CREATE INDEX ix_matricula_turma ON academico.matricula USING btree (turma_id);
```

**Consulta medida:**

```sql
SELECT a.matricula, a.nome, h.media_final, h.situacao FROM matricula m JOIN aluno a ON a.id = m.aluno_id JOIN historico h ON h.matricula_id = m.id WHERE m.turma_id = 1579 ORDER BY a.nome;
```

**ANTES — Seq Scan (aluno); Seq Scan (matricula); Index Scan (historico_matricula_id_key) — 6,873 ms (mediana), 780 páginas**

```
Sort  (cost=2102.14..2102.23 rows=36 width=43) (actual time=8.201..8.206 rows=40 loops=1)
  Sort Key: a.nome
  Sort Method: quicksort  Memory: 27kB
  Buffers: shared hit=780
  ->  Nested Loop  (cost=1668.31..2101.21 rows=36 width=43) (actual time=6.957..8.148 rows=40 loops=1)
        Buffers: shared hit=777
        ->  Hash Join  (cost=1668.01..1810.05 rows=36 width=37) (actual time=6.928..7.850 rows=40 loops=1)
              Hash Cond: (a.id = m.aluno_id)
              Buffers: shared hit=657
              ->  Seq Scan on aluno a  (cost=0.00..132.04 rows=3804 width=37) (actual time=0.004..0.479 rows=3804 loops=1)
                    Buffers: shared hit=94
              ->  Hash  (cost=1667.56..1667.56 rows=36 width=8) (actual time=6.889..6.889 rows=40 loops=1)
                    Buckets: 1024  Batches: 1  Memory Usage: 10kB
                    Buffers: shared hit=563
                    ->  Seq Scan on matricula m  (cost=0.00..1667.56 rows=36 width=8) (actual time=3.817..6.835 rows=40 loops=1)
                          Filter: (turma_id = 1579)
                          Rows Removed by Filter: 88325
                          Buffers: shared hit=563
        ->  Index Scan using historico_matricula_id_key on historico h  (cost=0.29..8.09 rows=1 width=14) (actual time=0.007..0.007 rows=1 loops=40)
              Index Cond: (matricula_id = m.id)
              Buffers: shared hit=120
Planning:
  Buffers: shared hit=433
Planning Time: 1.442 ms
Execution Time: 8.323 ms
```

**DEPOIS — Seq Scan (aluno); Index Scan (ix_matricula_turma); Index Scan (historico_matricula_id_key) — 1,062 ms (mediana), 250 páginas**

```
Sort  (cost=447.68..447.77 rows=36 width=43) (actual time=0.923..0.926 rows=40 loops=1)
  Sort Key: a.nome
  Sort Method: quicksort  Memory: 27kB
  Buffers: shared hit=250
  ->  Nested Loop  (cost=13.84..446.75 rows=36 width=43) (actual time=0.127..0.886 rows=40 loops=1)
        Buffers: shared hit=247
        ->  Hash Join  (cost=13.55..155.59 rows=36 width=37) (actual time=0.115..0.736 rows=40 loops=1)
              Hash Cond: (a.id = m.aluno_id)
              Buffers: shared hit=127
              ->  Seq Scan on aluno a  (cost=0.00..132.04 rows=3804 width=37) (actual time=0.003..0.309 rows=3804 loops=1)
                    Buffers: shared hit=94
              ->  Hash  (cost=13.10..13.10 rows=36 width=8) (actual time=0.091..0.092 rows=40 loops=1)
                    Buckets: 1024  Batches: 1  Memory Usage: 10kB
                    Buffers: shared hit=33
                    ->  Index Scan using ix_matricula_turma on matricula m  (cost=0.29..13.10 rows=36 width=8) (actual time=0.018..0.080 rows=40 loops=1)
                          Index Cond: (turma_id = 1579)
                          Buffers: shared hit=33
        ->  Index Scan using historico_matricula_id_key on historico h  (cost=0.29..8.09 rows=1 width=14) (actual time=0.003..0.003 rows=1 loops=40)
              Index Cond: (matricula_id = m.id)
              Buffers: shared hit=120
Planning:
  Buffers: shared hit=445
Planning Time: 1.031 ms
Execution Time: 1.015 ms
```

**Ganho medido:** 6,5× mais rápido; de 780 para 250 páginas lidas.

**Leitura do plano:** O índice troca o Seq Scan em `matricula` (563 páginas só nesse nó) por um Index Scan que lê poucas páginas. A junção com `aluno` continua por hash porque a tabela de alunos é pequena; o ganho vem todo do acesso a `matricula`.

**Segunda evidência:** Checagem da FK ao apagar uma turma (ON DELETE RESTRICT): DELETE da turma vazia 2386, dentro de BEGIN/ROLLBACK.

```sql
BEGIN;
EXPLAIN (ANALYZE, BUFFERS) DELETE FROM turma WHERE id = 2386;
ROLLBACK;
```

ANTES (repare na linha `Trigger for constraint matricula_turma_id_fkey`):

```
Delete on turma  (cost=0.28..8.30 rows=0 width=0) (actual time=0.090..0.090 rows=0 loops=1)
  Buffers: shared hit=12
  ->  Index Scan using uq_turma_id_periodo on turma  (cost=0.28..8.30 rows=1 width=6) (actual time=0.021..0.021 rows=1 loops=1)
        Index Cond: (id = 2386)
        Buffers: shared hit=3
Planning:
  Buffers: shared hit=103
Planning Time: 0.283 ms
Trigger for constraint fk_horario_turma: time=0.356 calls=1
Trigger for constraint matricula_turma_id_fkey: time=3.923 calls=1
Trigger for constraint demo_concorrencia_turma_id_fkey: time=0.257 calls=1
Execution Time: 4.680 ms
```

DEPOIS:

```
Delete on turma  (cost=0.28..8.30 rows=0 width=0) (actual time=0.080..0.081 rows=0 loops=1)
  Buffers: shared hit=12
  ->  Index Scan using uq_turma_id_periodo on turma  (cost=0.28..8.30 rows=1 width=6) (actual time=0.019..0.020 rows=1 loops=1)
        Index Cond: (id = 2386)
        Buffers: shared hit=3
Planning:
  Buffers: shared hit=103
Planning Time: 0.242 ms
Trigger for constraint fk_horario_turma: time=0.252 calls=1
Trigger for constraint matricula_turma_id_fkey: time=0.318 calls=1
Trigger for constraint demo_concorrencia_turma_id_fkey: time=0.132 calls=1
Execution Time: 0.829 ms
```

**Ganho na checagem da FK:** 7,141 ms → 0,378 ms (19×). Sem índice na FK, cada exclusão de turma varre a tabela de matrículas inteira.

---

## 3. `ix_historico_risco_falta` — B-tree PARCIAL

**Pergunta que o índice atende:** Quem está CURSANDO e já está abaixo de 75% de frequência (risco de reprovar por falta)?

```sql
CREATE INDEX ix_historico_risco_falta ON academico.historico USING btree (frequencia) WHERE ((situacao = 'CURSANDO'::tp_situacao_historico) AND ((frequencia)::numeric < (75)::numeric));
```

**Consulta medida:**

```sql
SELECT h.matricula_id, h.frequencia FROM historico h WHERE h.situacao = 'CURSANDO' AND h.frequencia < 75 ORDER BY h.frequencia;
```

**ANTES — Seq Scan (historico) — 12,904 ms (mediana), 898 páginas**

```
Sort  (cost=2283.13..2286.19 rows=1222 width=10) (actual time=13.602..13.676 rows=1279 loops=1)
  Sort Key: frequencia
  Sort Method: quicksort  Memory: 98kB
  Buffers: shared hit=898
  ->  Seq Scan on historico h  (cost=0.00..2220.47 rows=1222 width=10) (actual time=11.007..13.166 rows=1279 loops=1)
        Filter: (((frequencia)::numeric < '75'::numeric) AND (situacao = 'CURSANDO'::tp_situacao_historico))
        Rows Removed by Filter: 87086
        Buffers: shared hit=895
Planning:
  Buffers: shared hit=78
Planning Time: 0.396 ms
Execution Time: 13.760 ms
```

**DEPOIS — Bitmap Heap Scan (historico); Bitmap Index Scan (ix_historico_risco_falta) — 0,948 ms (mediana), 133 páginas**

```
Sort  (cost=1055.29..1058.40 rows=1245 width=10) (actual time=1.190..1.273 rows=1279 loops=1)
  Sort Key: frequencia
  Sort Method: quicksort  Memory: 98kB
  Buffers: shared hit=133
  ->  Bitmap Heap Scan on historico h  (cost=30.81..991.28 rows=1245 width=10) (actual time=0.115..0.723 rows=1279 loops=1)
        Recheck Cond: ((situacao = 'CURSANDO'::tp_situacao_historico) AND ((frequencia)::numeric < '75'::numeric))
        Heap Blocks: exact=125
        Buffers: shared hit=130
        ->  Bitmap Index Scan on ix_historico_risco_falta  (cost=0.00..30.50 rows=1245 width=0) (actual time=0.079..0.080 rows=1279 loops=1)
              Buffers: shared hit=5
Planning:
  Buffers: shared hit=96
Planning Time: 0.648 ms
Execution Time: 1.381 ms
```

**Ganho medido:** 14× mais rápido; de 898 para 133 páginas lidas.

**Leitura do plano:** Das ~88 mil linhas, só ~1,3 mil satisfazem `situacao = 'CURSANDO' AND frequencia < 75`. O índice parcial guarda só essas: 48 kB. Sem ele, o banco lê a tabela inteira e descarta ~87 mil linhas (`Rows Removed by Filter`).

---

## 4. `ix_aluno_nome_trgm` — GIN (trigramas, pg_trgm)

**Pergunta que o índice atende:** Busca da secretaria por um trecho do nome, em qualquer posição e sem diferenciar maiúsculas.

```sql
CREATE INDEX ix_aluno_nome_trgm ON academico.aluno USING gin (nome gin_trgm_ops);
```

**Consulta medida:**

```sql
SELECT matricula, nome FROM aluno WHERE nome ILIKE '%souza peixoto%';
```

**ANTES — Seq Scan (aluno) — 2,959 ms (mediana), 94 páginas**

```
Seq Scan on aluno  (cost=0.00..141.55 rows=1 width=33) (actual time=0.653..1.735 rows=1 loops=1)
  Filter: ((nome)::text ~~* '%souza peixoto%'::text)
  Rows Removed by Filter: 3803
  Buffers: shared hit=94
Planning:
  Buffers: shared hit=137
Planning Time: 0.405 ms
Execution Time: 1.765 ms
```

**DEPOIS — Bitmap Heap Scan (aluno); Bitmap Index Scan (ix_aluno_nome_trgm) — 0,303 ms (mediana), 26 páginas**

```
Bitmap Heap Scan on aluno  (cost=99.58..103.59 rows=1 width=33) (actual time=0.211..0.211 rows=1 loops=1)
  Recheck Cond: ((nome)::text ~~* '%souza peixoto%'::text)
  Rows Removed by Index Recheck: 2
  Heap Blocks: exact=3
  Buffers: shared hit=26
  ->  Bitmap Index Scan on ix_aluno_nome_trgm  (cost=0.00..99.58 rows=1 width=0) (actual time=0.172..0.172 rows=3 loops=1)
        Index Cond: ((nome)::text ~~* '%souza peixoto%'::text)
        Buffers: shared hit=23
Planning:
  Buffers: shared hit=168
Planning Time: 1.314 ms
Execution Time: 0.314 ms
```

**Ganho medido:** 9,8× mais rápido; de 94 para 26 páginas lidas.

**Leitura do plano:** O padrão começa com `%`, então nenhum B-tree ajudaria. O GIN de trigramas encontra os candidatos e o `Recheck` confirma o ILIKE. Para trechos muito comuns (ex.: 'silva'), o otimizador prefere o Seq Scan, porque a tabela de alunos é pequena (94 páginas): decisão de custo, não erro.

---

## 5. `ix_matricula_data_brin` — BRIN (pages_per_range = 8)

**Pergunta que o índice atende:** Quantas matrículas foram feitas na semana de 13 a 19/07/2026 (janela de matrícula)?

```sql
CREATE INDEX ix_matricula_data_brin ON academico.matricula USING brin (data_matricula) WITH (pages_per_range='8');
```

**Consulta medida:**

```sql
SELECT count(*) FROM matricula WHERE data_matricula >= '2026-07-13' AND data_matricula < '2026-07-20';
```

**ANTES — Seq Scan (matricula) — 6,809 ms (mediana), 563 páginas**

```
Aggregate  (cost=1897.48..1897.49 rows=1 width=8) (actual time=7.503..7.505 rows=1 loops=1)
  Buffers: shared hit=563
  ->  Seq Scan on matricula  (cost=0.00..1888.47 rows=3603 width=0) (actual time=6.074..7.267 rows=3667 loops=1)
        Filter: ((data_matricula >= '2026-07-13 00:00:00-03'::timestamp with time zone) AND (data_matricula < '2026-07-20 00:00:00-03'::timestamp with time zone))
        Rows Removed by Filter: 84698
        Buffers: shared hit=563
Planning:
  Buffers: shared hit=107
Planning Time: 0.471 ms
Execution Time: 7.581 ms
```

**DEPOIS — Bitmap Heap Scan (matricula); Bitmap Index Scan (ix_matricula_data_brin) — 0,905 ms (mediana), 41 páginas**

```
Aggregate  (cost=660.29..660.30 rows=1 width=8) (actual time=1.028..1.029 rows=1 loops=1)
  Buffers: shared hit=41
  ->  Bitmap Heap Scan on matricula  (cost=12.97..650.64 rows=3860 width=0) (actual time=0.117..0.790 rows=3667 loops=1)
        Recheck Cond: ((data_matricula >= '2026-07-13 00:00:00-03'::timestamp with time zone) AND (data_matricula < '2026-07-20 00:00:00-03'::timestamp with time zone))
        Rows Removed by Index Recheck: 1357
        Heap Blocks: lossy=32
        Buffers: shared hit=41
        ->  Bitmap Index Scan on ix_matricula_data_brin  (cost=0.00..12.01 rows=4978 width=0) (actual time=0.046..0.046 rows=320 loops=1)
              Index Cond: ((data_matricula >= '2026-07-13 00:00:00-03'::timestamp with time zone) AND (data_matricula < '2026-07-20 00:00:00-03'::timestamp with time zone))
              Buffers: shared hit=9
Planning:
  Buffers: shared hit=128
Planning Time: 0.536 ms
Execution Time: 1.102 ms
```

**Ganho medido:** 7,5× mais rápido; de 563 para 41 páginas lidas.

**Leitura do plano:** A coluna `data_matricula` tem correlação física 1 (as linhas foram gravadas em ordem cronológica). O BRIN guarda só mínimo e máximo por faixa de 8 páginas: com 24 kB ele descarta quase todas as faixas. `Rows Removed by Index Recheck` mostra as linhas das faixas vizinhas que precisaram ser conferidas.

---

## 6. `ix_log_auditoria_dados` — GIN jsonb_path_ops (bônus)

**Pergunta que o índice atende:** Tudo o que aconteceu com as notas da matrícula 4321 (busca DENTRO do JSONB com @>).

```sql
CREATE INDEX ix_log_auditoria_dados ON academico.log_auditoria USING gin (dados jsonb_path_ops);
```

**Consulta medida:**

```sql
SELECT id, momento, usuario, operacao FROM log_auditoria WHERE dados @> '{"depois": {"matricula_id": 4321}}';
```

**ANTES — Seq Scan (log_auditoria) — 29,652 ms (mediana), 4319 páginas**

```
Seq Scan on log_auditoria  (cost=0.00..5423.56 rows=9 width=37) (actual time=1.260..28.351 rows=1 loops=1)
  Filter: (dados @> '{"depois": {"matricula_id": 4321}}'::jsonb)
  Rows Removed by Filter: 88364
  Buffers: shared hit=4319
Planning:
  Buffers: shared hit=93
Planning Time: 0.315 ms
Execution Time: 28.381 ms
```

**DEPOIS — Bitmap Heap Scan (log_auditoria); Bitmap Index Scan (ix_log_auditoria_dados) — 0,071 ms (mediana), 5 páginas**

```
Bitmap Heap Scan on log_auditoria  (cost=17.14..52.02 rows=9 width=37) (actual time=0.037..0.038 rows=1 loops=1)
  Recheck Cond: (dados @> '{"depois": {"matricula_id": 4321}}'::jsonb)
  Heap Blocks: exact=1
  Buffers: shared hit=5
  ->  Bitmap Index Scan on ix_log_auditoria_dados  (cost=0.00..17.14 rows=9 width=0) (actual time=0.023..0.024 rows=1 loops=1)
        Index Cond: (dados @> '{"depois": {"matricula_id": 4321}}'::jsonb)
        Buffers: shared hit=4
Planning:
  Buffers: shared hit=119
Planning Time: 0.532 ms
Execution Time: 0.102 ms
```

**Ganho medido:** 418× mais rápido; de 4319 para 5 páginas lidas.

**Leitura do plano:** Sem índice, o banco abre e examina cada um dos ~88 mil documentos JSONB. O GIN é um índice invertido: aponta direto para os documentos que contêm `{"depois": {"matricula_id": 4321}}`. O preço é o tamanho (o GIN indexa cada valor de cada documento), aceitável para um log que é muito consultado em auditoria.
