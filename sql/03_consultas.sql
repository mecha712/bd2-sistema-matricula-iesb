-- #####################################################################
-- ##  03_consultas.sql — AS 10 CONSULTAS (MARCO 1)                     ##
-- ##  Projeto Acadêmico · Banco de Dados II (CCO072) · IESB · 2026/2   ##
-- #####################################################################
--
-- Dez consultas em ordem CRESCENTE de complexidade. As cinco exigidas pelo
-- enunciado estão marcadas com [OBRIGATÓRIA]:
--   5  junção externa com agregação
--   7  recursiva: árvore de pré-requisitos
--   8  recursiva: disciplinas que um aluno já pode cursar
--   9  função de janela com ranking e percentil
--   10 função de janela com LAG (evolução do rendimento)
--
-- Só leitura: rodar este arquivo não altera nada no banco.
-- Alunos usados nos exemplos (CCO noturno, entraram em 2024/2):
--   2024200005 Enzo     - reprovou Algoritmos (CCO011) no 1º semestre, e
--                         isso atrasou toda a cadeia até Banco de Dados II;
--   2024200015 Leonardo - em dia: está cursando Banco de Dados II agora.
-- Troque o número nas consultas 3, 8 e 10 para ver outro aluno.
-- =====================================================================

SET search_path TO academico, public;


-- ---------------------------------------------------------------------
-- CONSULTA 1 — 10 alunos em ordem alfabética
-- TÉCNICA: SELECT com ORDER BY + LIMIT.
-- ATENÇÃO: sem ORDER BY, "os 10 primeiros"
--   não quer dizer nada; o banco devolve as linhas na ordem que for mais
--   barata, e essa ordem pode mudar de uma execução para outra.
--   O desempate por matrícula garante resultado estável com nomes iguais.
-- ---------------------------------------------------------------------
SELECT matricula, nome, email
  FROM aluno
 ORDER BY nome, matricula
 LIMIT 10;


-- ---------------------------------------------------------------------
-- CONSULTA 2 — Onde e quando são as aulas de Banco de Dados II em 2026/2?
-- TÉCNICA: INNER JOIN de 5 tabelas + agregação de texto (string_agg).
-- POR QUE string_agg: cada turma tem 2 encontros (2 linhas em
--   turma_horario); agregando, mostramos uma linha por turma.
--   (No MySQL o equivalente seria GROUP_CONCAT.)
-- ---------------------------------------------------------------------
SELECT t.codigo AS turma,
       t.turno,
       t.vagas,
       string_agg(CASE th.dia_semana WHEN 1 THEN 'SEG' WHEN 2 THEN 'TER' WHEN 3 THEN 'QUA'
                                     WHEN 4 THEN 'QUI' WHEN 5 THEN 'SEX' WHEN 6 THEN 'SÁB' ELSE 'DOM' END
                  || ' ' || to_char(th.hora_inicio, 'HH24:MI') || '-' || to_char(th.hora_fim, 'HH24:MI')
                  || ' (' || s.codigo || ')',
                  ' | ' ORDER BY th.dia_semana) AS horarios
  FROM turma t
  JOIN disciplina d     ON d.id = t.disciplina_id
  JOIN periodo_letivo p ON p.id = t.periodo_letivo_id
  JOIN turma_horario th ON th.turma_id = t.id
  JOIN sala s           ON s.id = th.sala_id
 WHERE d.codigo = 'CCO072'
   AND p.vigente
 GROUP BY t.id, t.codigo, t.turno, t.vagas
 ORDER BY t.codigo;


-- ---------------------------------------------------------------------
-- CONSULTA 3 — Histórico escolar de um aluno
-- TÉCNICA: junção em cadeia de 6 tabelas (aluno -> matrícula -> turma ->
--   disciplina / período, e matrícula -> histórico), ordenada no tempo.
-- POR QUE ||: monta o texto "2024/2". (No MySQL, || é OU lógico; lá seria
--   CONCAT(ano, '/', semestre).)
-- ---------------------------------------------------------------------
SELECT p.ano || '/' || p.semestre AS periodo,
       d.codigo,
       d.nome       AS disciplina,
       h.nota_a1, h.nota_a2, h.nota_p3,
       h.media_final,
       h.frequencia,
       h.situacao
  FROM aluno a
  JOIN matricula m      ON m.aluno_id = a.id
  JOIN turma t          ON t.id = m.turma_id
  JOIN disciplina d     ON d.id = t.disciplina_id
  JOIN periodo_letivo p ON p.id = t.periodo_letivo_id
  JOIN historico h      ON h.matricula_id = m.id
 WHERE a.matricula = '2024200005'
 ORDER BY p.ano, p.semestre, d.codigo;


-- ---------------------------------------------------------------------
-- CONSULTA 4 — Disciplinas "difíceis": taxa de reprovação acima de 30%
-- TÉCNICA: GROUP BY + HAVING + agregados condicionais (FILTER).
-- POR QUE HAVING e não WHERE: o WHERE filtra LINHAS antes de agrupar; o
--   HAVING filtra GRUPOS depois de calculados os agregados. A taxa só existe
--   depois do agrupamento.
-- POR QUE FILTER: conta só as linhas que satisfazem a condição. (No MySQL:
--   SUM(CASE WHEN ... THEN 1 ELSE 0 END).)
-- ---------------------------------------------------------------------
SELECT d.codigo,
       d.nome,
       count(*)                                                       AS cursaram,
       count(*) FILTER (WHERE h.situacao = 'REPROVADO_NOTA')          AS reprov_nota,
       count(*) FILTER (WHERE h.situacao = 'REPROVADO_FALTA')         AS reprov_falta,
       round(100.0 * count(*) FILTER (WHERE h.situacao <> 'APROVADO') / count(*), 1) AS taxa_reprovacao
  FROM historico h
  JOIN matricula m  ON m.id = h.matricula_id
  JOIN turma t      ON t.id = m.turma_id
  JOIN disciplina d ON d.id = t.disciplina_id
 WHERE h.situacao <> 'CURSANDO'                       -- só semestres encerrados
 GROUP BY d.id, d.codigo, d.nome
HAVING 100.0 * count(*) FILTER (WHERE h.situacao <> 'APROVADO') / count(*) > 30
 ORDER BY taxa_reprovacao DESC;


-- ---------------------------------------------------------------------
-- CONSULTA 5 [OBRIGATÓRIA] — JUNÇÃO EXTERNA COM AGREGAÇÃO
-- Ocupação de TODAS as turmas de 2026/2, inclusive as que não têm aluno.
-- TÉCNICA: LEFT JOIN + count(coluna) + GROUP BY.
-- POR QUE LEFT JOIN: com INNER JOIN as turmas vazias SUMIRIAM do resultado
--   (não têm par em matrícula). O LEFT preserva toda turma e preenche o
--   lado da matrícula com NULO.
-- POR QUE count(m.id) e não count(*): na turma vazia o LEFT JOIN gera UMA
--   linha com m.id nulo; count(*) contaria essa linha como 1 aluno;
--   count(m.id) ignora nulos e devolve 0, que é o certo.
-- ---------------------------------------------------------------------
SELECT t.codigo                                     AS turma,
       d.codigo                                     AS disciplina,
       t.turno,
       t.vagas,
       count(m.id)                                  AS matriculados,
       t.vagas - count(m.id)                        AS vagas_livres,
       round(100.0 * count(m.id) / t.vagas, 1)      AS pct_ocupacao
  FROM turma t
  JOIN disciplina d     ON d.id = t.disciplina_id
  JOIN periodo_letivo p ON p.id = t.periodo_letivo_id AND p.vigente
  LEFT JOIN matricula m ON m.turma_id = t.id AND m.status = 'MATRICULADO'
 GROUP BY t.id, t.codigo, d.codigo, t.turno, t.vagas
 ORDER BY pct_ocupacao, t.codigo
 LIMIT 12;
-- ATENÇÃO ao detalhe: a condição m.status = 'MATRICULADO' está no ON, não
-- no WHERE. No WHERE, ela descartaria as linhas com m nulo e o LEFT JOIN
-- viraria, na prática, um INNER JOIN (as turmas vazias sumiriam de novo).


-- ---------------------------------------------------------------------
-- CONSULTA 6 — Alunos ativos SEM matrícula em 2026/2 (risco de evasão)
-- TÉCNICA: NOT EXISTS (anti-junção) + subconsulta correlacionada.
-- POR QUE NOT EXISTS e não NOT IN: se a lista do NOT IN tiver um único
--   NULO, o resultado inteiro vira vazio, sem erro. NOT EXISTS é imune.
-- CORRELACIONADA: a subconsulta do "último período" usa a.id da consulta
--   de fora; por isso é reexecutada para cada aluno.
-- ---------------------------------------------------------------------
SELECT a.matricula,
       a.nome,
       coalesce(c.codigo, '(sem curso)') AS curso,
       (SELECT max(p2.ano || '/' || p2.semestre)
          FROM matricula m2
          JOIN turma t2           ON t2.id = m2.turma_id
          JOIN periodo_letivo p2  ON p2.id = t2.periodo_letivo_id
         WHERE m2.aluno_id = a.id) AS ultimo_periodo_cursado
  FROM aluno a
  LEFT JOIN curso c ON c.id = a.curso_id
 WHERE a.situacao = 'ATIVO'
   AND NOT EXISTS (SELECT 1
                     FROM matricula m
                     JOIN turma t          ON t.id = m.turma_id
                     JOIN periodo_letivo p ON p.id = t.periodo_letivo_id AND p.vigente
                    WHERE m.aluno_id = a.id)
 ORDER BY ultimo_periodo_cursado NULLS FIRST, a.matricula;


-- ---------------------------------------------------------------------
-- CONSULTA 7 [OBRIGATÓRIA] — RECURSIVA: ÁRVORE DE PRÉ-REQUISITOS de CCO072
-- Tudo o que é preciso ter cursado antes de Banco de Dados II, em todos os
-- níveis, com o caminho percorrido.
-- ESTRUTURA DE TODA CTE RECURSIVA:
--   (1) âncora: o ponto de partida (roda uma vez);
--   (2) UNION ALL;
--   (3) termo recursivo: usa a própria CTE e se repete até não achar nada.
-- PROTEÇÃO: o array "visitados" guarda o caminho; se uma disciplina já
--   está nele, o ramo para (evita laço infinito se um dia houver ciclo).
--   O nível máximo é a segunda trava. (No PostgreSQL 14+ existe também a
--   cláusula padrão CYCLE, que faz a mesma coisa.)
-- REPARE: MDC118 aparece duas vezes, por caminhos diferentes (CCO061 exige
--   MDC118 direto e também via CCO041). Isso NÃO é ciclo, é um losango.
-- ---------------------------------------------------------------------
WITH RECURSIVE arvore AS (
    -- (1) âncora
    SELECT d.id, d.codigo, d.nome,
           0                AS nivel,
           ARRAY[d.id]      AS visitados,
           d.codigo::text   AS caminho
      FROM disciplina d
     WHERE d.codigo = 'CCO072'

    UNION ALL

    -- (3) termo recursivo: os pré-requisitos das disciplinas já encontradas
    SELECT req.id, req.codigo, req.nome,
           a.nivel + 1,
           a.visitados || req.id,
           a.caminho || ' <- ' || req.codigo
      FROM arvore a
      JOIN pre_requisito pr ON pr.disciplina_id = a.id
      JOIN disciplina req   ON req.id = pr.requisito_id
     WHERE req.id <> ALL (a.visitados)   -- proteção 1: não revisita no mesmo caminho
       AND a.nivel < 20                  -- proteção 2: profundidade máxima
)
SELECT nivel,
       repeat('    ', nivel) || codigo || ' - ' || nome AS arvore,
       caminho
  FROM arvore
 ORDER BY caminho;


-- ---------------------------------------------------------------------
-- CONSULTA 8 [OBRIGATÓRIA] — RECURSIVA: DISCIPLINAS QUE O ALUNO JÁ PODE CURSAR
-- Regra: a disciplina está LIBERADA se é do currículo do curso do aluno,
--   se ele ainda não foi aprovado nela e se TODOS os pré-requisitos dela,
--   diretos e indiretos (a árvore inteira, em qualquer nível), já foram
--   aprovados.
-- TÉCNICA: CTE recursiva que calcula o FECHO TRANSITIVO dos pré-requisitos
--   (para cada disciplina, todos os seus requisitos em todos os níveis) +
--   dupla negação com NOT EXISTS ("não existe requisito não aprovado").
-- POR QUE UNION (e não UNION ALL) no recursivo: o UNION descarta pares
--   repetidos; com isso a recursão termina mesmo que houvesse ciclo.
-- ---------------------------------------------------------------------
WITH RECURSIVE
aluno_alvo AS (
    SELECT id, curso_id FROM aluno WHERE matricula = '2024200005'
),
aprovadas AS (             -- disciplinas em que o aluno já foi aprovado
    SELECT DISTINCT t.disciplina_id
      FROM matricula m
      JOIN historico h ON h.matricula_id = m.id
      JOIN turma t     ON t.id = m.turma_id
     WHERE m.aluno_id = (SELECT id FROM aluno_alvo)
       AND h.situacao = 'APROVADO'
),
cursando AS (              -- disciplinas em que ele está matriculado agora
    SELECT t.disciplina_id
      FROM matricula m
      JOIN turma t ON t.id = m.turma_id
     WHERE m.aluno_id = (SELECT id FROM aluno_alvo)
       AND m.status = 'MATRICULADO'
),
fecho (disciplina_id, requisito_id) AS (
    -- âncora: os pré-requisitos diretos
    SELECT disciplina_id, requisito_id FROM pre_requisito
    UNION
    -- recursivo: o requisito do meu requisito também é meu requisito
    SELECT f.disciplina_id, pr.requisito_id
      FROM fecho f
      JOIN pre_requisito pr ON pr.disciplina_id = f.requisito_id
)
SELECT cd.semestre_ideal,
       d.codigo,
       d.nome,
       (SELECT count(*) FROM fecho f WHERE f.disciplina_id = d.id) AS requisitos_na_arvore,
       CASE WHEN d.id IN (SELECT disciplina_id FROM cursando)
            THEN 'cursando agora' ELSE 'liberada para matrícula' END AS situacao
  FROM aluno_alvo a
  JOIN curriculo cu            ON cu.curso_id = a.curso_id AND cu.vigente
  JOIN curriculo_disciplina cd ON cd.curriculo_id = cu.id
  JOIN disciplina d            ON d.id = cd.disciplina_id
 WHERE NOT EXISTS (SELECT 1 FROM aprovadas ap WHERE ap.disciplina_id = d.id)
   AND NOT EXISTS (SELECT 1
                     FROM fecho f
                    WHERE f.disciplina_id = d.id
                      AND NOT EXISTS (SELECT 1 FROM aprovadas ap WHERE ap.disciplina_id = f.requisito_id))
 ORDER BY cd.semestre_ideal, d.codigo;
-- Repare: CCO072 (BD II) NÃO aparece para este aluno. Ele reprovou
-- Algoritmos (CCO011) no 1º semestre; a árvore de BD II passa por
-- CCO011 -> CCO021 -> CCO041 -> CCO061, e ele ainda não fechou essa cadeia.
-- É exatamente por isso que a consulta precisa ser recursiva: o bloqueio
-- pode estar em qualquer nível da árvore, não só no pré-requisito direto.


-- ---------------------------------------------------------------------
-- CONSULTA 9 [OBRIGATÓRIA] — FUNÇÃO DE JANELA COM RANKING E PERCENTIL
-- Os 5 melhores alunos ativos de cada curso pelo Coeficiente de Rendimento
-- (CR = média das médias finais ponderada pela carga horária).
-- TÉCNICA:
--   rank()         : posição; empates dividem a posição e pulam a seguinte
--   dense_rank()   : idem, mas sem pular
--   percent_rank() : percentil — fração dos colegas do curso com CR menor
--   ntile(4)       : quartil (divide o curso em 4 faixas)
--   percentile_cont(0.5) : a MEDIANA do curso (agregado de conjunto ordenado,
--                          calculado num GROUP BY e juntado por curso)
-- PARTITION BY curso faz o ranking REINICIAR em cada curso.
-- Funções de janela não podem ir no WHERE: filtramos a posição por fora.
-- ---------------------------------------------------------------------
WITH cr AS (
    SELECT a.id, a.matricula, a.nome, c.codigo AS curso,
           round(sum(h.media_final * d.ch_total) / sum(d.ch_total), 2) AS cr,
           count(*) AS disciplinas_concluidas
      FROM aluno a
      JOIN curso c      ON c.id = a.curso_id
      JOIN matricula m  ON m.aluno_id = a.id
      JOIN historico h  ON h.matricula_id = m.id
      JOIN turma t      ON t.id = m.turma_id
      JOIN disciplina d ON d.id = t.disciplina_id
     WHERE a.situacao = 'ATIVO'
       AND h.media_final IS NOT NULL
     GROUP BY a.id, a.matricula, a.nome, c.codigo
    HAVING count(*) >= 10
),
mediana AS (
    SELECT curso, percentile_cont(0.5) WITHIN GROUP (ORDER BY cr) AS mediana_cr
      FROM cr GROUP BY curso
),
ranking AS (
    SELECT cr.*,
           rank()       OVER w                                AS posicao,
           dense_rank() OVER w                                AS posicao_densa,
           round((100 * percent_rank() OVER (PARTITION BY curso ORDER BY cr))::numeric, 1) AS percentil,
           ntile(4)     OVER w                                AS quartil
      FROM cr
    WINDOW w AS (PARTITION BY curso ORDER BY cr DESC)
)
SELECT r.curso, r.posicao, r.posicao_densa, r.matricula, r.nome, r.cr,
       r.percentil, r.quartil, round(m.mediana_cr::numeric, 2) AS mediana_do_curso
  FROM ranking r
  JOIN mediana m ON m.curso = r.curso
 WHERE r.posicao <= 5
 ORDER BY r.curso, r.posicao, r.matricula;


-- ---------------------------------------------------------------------
-- CONSULTA 10 [OBRIGATÓRIA] — FUNÇÃO DE JANELA COM LAG: EVOLUÇÃO DO RENDIMENTO
-- Média de cada aluno em cada semestre, comparada com o semestre anterior.
-- TÉCNICA: LAG(x) olha a linha ANTERIOR dentro da janela; PARTITION BY
--   aluno faz cada aluno ter a sua própria sequência (o primeiro semestre de
--   cada um não tem anterior: LAG devolve NULO). LEAD olharia a seguinte.
--   A média acumulada usa a moldura ROWS BETWEEN UNBOUNDED PRECEDING AND
--   CURRENT ROW (do primeiro semestre até o atual).
-- ---------------------------------------------------------------------
WITH por_semestre AS (
    SELECT a.matricula, a.nome,
           p.ano, p.semestre,
           round(avg(h.media_final), 2) AS media_semestre,
           count(*) FILTER (WHERE h.situacao <> 'APROVADO') AS reprovacoes
      FROM aluno a
      JOIN matricula m      ON m.aluno_id = a.id
      JOIN historico h      ON h.matricula_id = m.id
      JOIN turma t          ON t.id = m.turma_id
      JOIN periodo_letivo p ON p.id = t.periodo_letivo_id
     WHERE a.matricula IN ('2024200015', '2024200005')
       AND h.media_final IS NOT NULL
     GROUP BY a.matricula, a.nome, p.ano, p.semestre
)
SELECT matricula,
       nome,
       ano || '/' || semestre                                   AS periodo,
       media_semestre,
       lag(media_semestre) OVER w                               AS media_anterior,
       media_semestre - lag(media_semestre) OVER w              AS variacao,
       CASE
         WHEN lag(media_semestre) OVER w IS NULL               THEN 'primeiro semestre'
         WHEN media_semestre > lag(media_semestre) OVER w      THEN 'melhorou'
         WHEN media_semestre < lag(media_semestre) OVER w      THEN 'piorou'
         ELSE 'estável'
       END                                                      AS tendencia,
       round(avg(media_semestre) OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2)
                                                                AS media_acumulada,
       reprovacoes
  FROM por_semestre
WINDOW w AS (PARTITION BY matricula ORDER BY ano, semestre)
 ORDER BY matricula, ano, semestre;
