-- #####################################################################
-- ##  04_views.sql — VIEWS E MATERIALIZED VIEW                         ##
-- ##  Projeto Acadêmico · Banco de Dados II (CCO072) · IESB · 2026/2   ##
-- ##  Frente: Administração e Operação                                 ##
-- #####################################################################
--
-- VIEW: consulta guardada com nome. NÃO armazena dados: toda vez que é
--   lida, a consulta por trás roda de novo. Dado sempre atual.
-- MATERIALIZED VIEW: o resultado FICA GRAVADO em disco. Leitura rápida,
--   mas o dado congela até alguém mandar REFRESH.
--
-- Aqui: 3 views (oferta, vagas, histórico) + 1 materialized view de
-- indicadores com política de atualização justificada (seção 4).
-- =====================================================================

SET search_path TO academico, public;


-- =====================================================================
-- 1. vw_oferta — o que está sendo oferecido no período vigente
-- Uma linha por turma, com os horários e salas juntados num texto só.
-- O array ['SEG',...][n] traduz o número do dia (1..7) para o nome.
-- LEFT JOIN nos horários: turma ainda sem horário definido também aparece.
-- =====================================================================
CREATE OR REPLACE VIEW vw_oferta AS
SELECT p.ano || '/' || p.semestre                       AS periodo,
       t.id                                             AS turma_id,
       t.codigo                                         AS turma,
       t.turno,
       d.codigo                                         AS disciplina_codigo,
       d.nome                                           AS disciplina,
       d.ch_total,
       t.vagas,
       string_agg((ARRAY['SEG','TER','QUA','QUI','SEX','SÁB','DOM'])[th.dia_semana]
                  || ' ' || to_char(th.hora_inicio, 'HH24:MI')
                  || '-' || to_char(th.hora_fim, 'HH24:MI')
                  || ' (' || s.codigo || ')',
                  ' | ' ORDER BY th.dia_semana, th.hora_inicio) AS horarios
  FROM turma t
  JOIN periodo_letivo p      ON p.id = t.periodo_letivo_id AND p.vigente
  JOIN disciplina d          ON d.id = t.disciplina_id
  LEFT JOIN turma_horario th ON th.turma_id = t.id
  LEFT JOIN sala s           ON s.id = th.sala_id
 GROUP BY p.ano, p.semestre, t.id, t.codigo, t.turno, d.codigo, d.nome, d.ch_total, t.vagas;

COMMENT ON VIEW vw_oferta IS 'Turmas do período vigente com horários e salas';


-- =====================================================================
-- 2. vw_vagas — situação de vagas de cada turma do período vigente
-- Só matrículas com status MATRICULADO ocupam vaga (trancada/cancelada
-- libera a vaga). É a mesma conta que a função de matrícula faz (06).
--
-- SEGURANÇA (de propósito): esta view roda com os privilégios do DONO
-- (padrão das views). Assim o aluno, que pelo RLS só enxerga as PRÓPRIAS
-- matrículas, consegue ver quantas vagas restam na turma, sem enxergar
-- QUEM está matriculado: a view só expõe números agregados.
-- =====================================================================
CREATE OR REPLACE VIEW vw_vagas AS
SELECT t.id                                           AS turma_id,
       t.codigo                                       AS turma,
       d.codigo                                       AS disciplina_codigo,
       d.nome                                         AS disciplina,
       t.turno,
       t.vagas,
       count(m.id)                                    AS ocupadas,
       t.vagas - count(m.id)                          AS restantes,
       round(100.0 * count(m.id) / t.vagas, 1)        AS pct_ocupacao,
       CASE WHEN count(m.id) >= t.vagas    THEN 'LOTADA'
            WHEN t.vagas - count(m.id) <= 5 THEN 'ÚLTIMAS VAGAS'
            ELSE 'DISPONÍVEL' END                     AS situacao
  FROM turma t
  JOIN periodo_letivo p ON p.id = t.periodo_letivo_id AND p.vigente
  JOIN disciplina d     ON d.id = t.disciplina_id
  -- a condição de status fica no ON (e não no WHERE) para preservar o LEFT JOIN
  LEFT JOIN matricula m ON m.turma_id = t.id AND m.status = 'MATRICULADO'
 GROUP BY t.id, t.codigo, d.codigo, d.nome, t.turno, t.vagas;

COMMENT ON VIEW vw_vagas IS 'Vagas, ocupação e situação das turmas do período vigente (só números, sem dados pessoais)';


-- =====================================================================
-- 3. vw_historico — histórico escolar (uma linha por disciplina cursada)
--
-- SEGURANÇA: security_invoker = true (PostgreSQL 15+). A view passa a
-- respeitar os privilégios e o RLS de QUEM CONSULTA. Sem isso, como o dono
-- da view é o superusuário (que ignora RLS), um aluno veria o histórico de
-- TODOS através da view: um furo clássico. Com ela, cada aluno só vê o seu.
-- =====================================================================
CREATE OR REPLACE VIEW vw_historico
WITH (security_invoker = true) AS
SELECT a.matricula                    AS matricula_aluno,
       a.nome                         AS aluno,
       c.codigo                       AS curso,
       p.ano || '/' || p.semestre     AS periodo,
       d.codigo                       AS disciplina_codigo,
       d.nome                         AS disciplina,
       t.codigo                       AS turma,
       h.nota_a1, h.nota_a2, h.nota_p3,
       h.media_final,
       h.frequencia,
       h.situacao
  FROM historico h
  JOIN matricula m      ON m.id = h.matricula_id
  JOIN aluno a          ON a.id = m.aluno_id
  LEFT JOIN curso c     ON c.id = a.curso_id
  JOIN turma t          ON t.id = m.turma_id
  JOIN disciplina d     ON d.id = t.disciplina_id
  JOIN periodo_letivo p ON p.id = t.periodo_letivo_id;

COMMENT ON VIEW vw_historico IS 'Histórico escolar; security_invoker: respeita o RLS de quem consulta';


-- =====================================================================
-- 4. mv_indicadores_disciplina — painel de indicadores por disciplina e período
--
-- POR QUE MATERIALIZADA: agrega ~90 mil históricos e calcula mediana
-- (percentile_cont), que exige ordenar. Recalcular isso a cada abertura do
-- painel da coordenação é desperdício: as notas não mudam a toda hora.
--
-- POLÍTICA DE ATUALIZAÇÃO (justificativa):
--   * As notas mudam em LOTES, em três janelas por semestre: fechamento da
--     A1, da A2 e da P3. Fora delas, os números praticamente não mudam.
--   * Logo, o REFRESH é feito (a) ao final de cada janela de lançamento,
--     pela secretaria ou coordenação, chamando fn_atualizar_indicadores();
--     e (b) uma vez por dia, de madrugada (02:00), por agendamento do
--     sistema operacional (ou pg_cron, onde existir), como rede de segurança.
--   * Defasagem tolerada: até 24 horas. É painel de acompanhamento, não
--     decisão em tempo real (para vaga em tempo real existe a vw_vagas).
--   * REFRESH ... CONCURRENTLY: quem está lendo o painel não fica bloqueado
--     durante a atualização. O custo: é mais lento que o refresh comum e
--     EXIGE um índice único na materialized view (criado logo abaixo).
--   * A coluna atualizado_em mostra quando o dado foi calculado: quem lê
--     sabe o quão "velho" ele está.
-- =====================================================================
DROP MATERIALIZED VIEW IF EXISTS mv_indicadores_disciplina;
CREATE MATERIALIZED VIEW mv_indicadores_disciplina AS
SELECT p.id                                                           AS periodo_letivo_id,
       p.ano || '/' || p.semestre                                     AS periodo,
       d.id                                                           AS disciplina_id,
       d.codigo                                                       AS disciplina_codigo,
       d.nome                                                         AS disciplina,
       count(DISTINCT t.id)                                           AS turmas,
       count(*)                                                       AS matriculados,
       count(*) FILTER (WHERE h.situacao <> 'CURSANDO')               AS concluintes,
       count(*) FILTER (WHERE h.situacao = 'APROVADO')                AS aprovados,
       count(*) FILTER (WHERE h.situacao = 'REPROVADO_NOTA')          AS reprovados_nota,
       count(*) FILTER (WHERE h.situacao = 'REPROVADO_FALTA')         AS reprovados_falta,
       round(100.0 * count(*) FILTER (WHERE h.situacao = 'APROVADO')
             / nullif(count(*) FILTER (WHERE h.situacao <> 'CURSANDO'), 0), 1) AS taxa_aprovacao,
       round(avg(h.media_final), 2)                                   AS media_final_media,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY h.media_final))::numeric, 2)
                                                                      AS media_final_mediana,
       round(avg(h.nota_a1), 2)                                       AS media_a1,
       round(avg(h.frequencia), 1)                                    AS frequencia_media,
       now()                                                          AS atualizado_em
  FROM historico h
  JOIN matricula m      ON m.id = h.matricula_id
  JOIN turma t          ON t.id = m.turma_id
  JOIN disciplina d     ON d.id = t.disciplina_id
  JOIN periodo_letivo p ON p.id = t.periodo_letivo_id
 GROUP BY p.id, p.ano, p.semestre, d.id, d.codigo, d.nome;

-- índice único: obrigatório para REFRESH ... CONCURRENTLY
CREATE UNIQUE INDEX uq_mv_indicadores_periodo_disciplina
    ON mv_indicadores_disciplina (periodo_letivo_id, disciplina_id);

COMMENT ON MATERIALIZED VIEW mv_indicadores_disciplina IS
  'Indicadores por disciplina e período. REFRESH CONCURRENTLY ao fim de cada janela de notas (A1, A2, P3) e diariamente às 02:00';

-- Atualização "oficial". SECURITY DEFINER porque só o DONO de uma
-- materialized view pode dar REFRESH; com a função, a coordenação pode
-- atualizar o painel sem precisar ser dona do objeto (o GRANT é no 07).
CREATE OR REPLACE FUNCTION fn_atualizar_indicadores()
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = academico, pg_catalog, pg_temp
AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY mv_indicadores_disciplina;
  RETURN (SELECT max(atualizado_em) FROM mv_indicadores_disciplina);
END $$;
COMMENT ON FUNCTION fn_atualizar_indicadores() IS 'REFRESH CONCURRENTLY do painel de indicadores (política no script 04)';


-- =====================================================================
-- 5. CONFERÊNCIA
-- =====================================================================
SELECT turma, disciplina_codigo, turno, horarios
  FROM vw_oferta WHERE disciplina_codigo = 'CCO072' ORDER BY turma;

SELECT situacao, count(*) AS turmas FROM vw_vagas GROUP BY situacao ORDER BY situacao;

SELECT periodo, disciplina_codigo, matriculados, taxa_aprovacao, media_final_media, media_final_mediana
  FROM mv_indicadores_disciplina
 WHERE disciplina_codigo = 'CCO072'
 ORDER BY periodo_letivo_id;
