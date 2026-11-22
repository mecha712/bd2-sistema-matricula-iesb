-- #####################################################################
-- ##  02_carga.sql — CARGA DE DADOS                                    ##
-- ##  Projeto Acadêmico · Banco de Dados II (CCO072) · IESB · 2026/2   ##
-- #####################################################################
--
-- O QUE ESTE SCRIPT FAZ
--   1. Cadastra a estrutura acadêmica: 10 períodos (2022/1 a 2026/2),
--      3 cursos (CCO, ESW, ADS), currículos, 56 disciplinas e a árvore de
--      pré-requisitos (BD II = CCO072 exige BD I = CCO061, e assim por diante).
--   2. SIMULA os 10 semestres, um de cada vez: entra uma turma de calouros,
--      cada aluno ativo se matricula nas disciplinas que pode cursar
--      (respeitando pré-requisitos), abrem-se as turmas necessárias,
--      lançam-se notas e frequência, e no fim do semestre há aprovações,
--      reprovações, formaturas e evasão.
--   3. Distribui as turmas em salas e horários sem choque.
--
-- VOLUME (muito acima do mínimo exigido de 100 alunos, 6 turmas e 300
--   matrículas): ~3.800 alunos, ~2.500 turmas e ~85 mil matrículas. O
--   volume é proposital: com poucas linhas tudo cabe em uma página de
--   disco e nenhum índice faz diferença; com dezenas de milhares, o ganho
--   dos índices aparece no EXPLAIN ANALYZE (script 05).
--
-- DADOS FICTÍCIOS E REPRODUTÍVEIS
--   Nomes, CPFs e notas são gerados. Em vez de random(), usamos um hash
--   (md5) de uma "semente" textual: o mesmo script gera EXATAMENTE os
--   mesmos dados em qualquer máquina e em qualquer versão do PostgreSQL.
--   generate_series é permitido pelo enunciado e é usado nos calouros.
--
-- TEMPO: de 10 a 40 segundos, conforme a máquina.
-- =====================================================================

SET search_path TO academico, public;
SET timezone TO 'America/Sao_Paulo';

-- ---------------------------------------------------------------------
-- Funções auxiliares TEMPORÁRIAS (schema pg_temp): existem só durante esta
-- sessão e somem sozinhas no fim. Não ficam no banco final.
-- ---------------------------------------------------------------------

-- número pseudoaleatório DETERMINÍSTICO em [0, 1) a partir de um texto
CREATE FUNCTION pg_temp.rnd(p_semente text)
RETURNS double precision
LANGUAGE sql IMMUTABLE AS $$
  SELECT ('x' || substr(md5(p_semente), 1, 8))::bit(32)::bigint / 4294967296.0
$$;

-- CPF válido (com dígitos verificadores) a partir de um número sequencial.
-- (n * 7919 + 13579) mod 10^9 é uma permutação: números diferentes geram
-- bases diferentes, então os CPFs nunca se repetem.
CREATE FUNCTION pg_temp.gera_cpf(p_n int)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  base text := lpad(((p_n::bigint * 7919 + 13579) % 1000000000)::text, 9, '0');
  soma int;
  i    int;
BEGIN
  soma := 0;
  FOR i IN 1..9 LOOP soma := soma + substr(base, i, 1)::int * (11 - i); END LOOP;
  base := base || ((soma * 10) % 11 % 10)::text;
  soma := 0;
  FOR i IN 1..10 LOOP soma := soma + substr(base, i, 1)::int * (12 - i); END LOOP;
  RETURN base || ((soma * 10) % 11 % 10)::text;
END $$;


-- =====================================================================
-- 1. PERÍODOS LETIVOS: 2022/1 a 2026/2 (o vigente é 2026/2)
-- =====================================================================
INSERT INTO periodo_letivo (ano, semestre, data_inicio, data_fim, vigente)
SELECT a.ano, s.sem,
       CASE s.sem WHEN 1 THEN make_date(a.ano, 2, 7) ELSE make_date(a.ano, 8, 3)  END,
       CASE s.sem WHEN 1 THEN make_date(a.ano, 6, 30) ELSE make_date(a.ano, 12, 12) END,
       (a.ano = 2026 AND s.sem = 2)
  FROM generate_series(2022, 2026) AS a(ano)
 CROSS JOIN (VALUES (1), (2)) AS s(sem)
 ORDER BY a.ano, s.sem;


-- =====================================================================
-- 2. CURSOS E CURRÍCULOS
-- =====================================================================
INSERT INTO curso (codigo, nome, grau, duracao_semestres) VALUES
  ('CCO', 'Ciência da Computação',                     'BACHARELADO', 8),
  ('ESW', 'Engenharia de Software',                    'BACHARELADO', 8),
  ('ADS', 'Análise e Desenvolvimento de Sistemas',     'TECNOLOGO',   5);

INSERT INTO curriculo (curso_id, versao, vigente)
SELECT id, '2022', true FROM curso ORDER BY id;


-- =====================================================================
-- 3. DISCIPLINAS E MATRIZ CURRICULAR
-- Cada linha: código, nome, CH teórica, CH prática, semestre ideal e os
-- cursos em que ela aparece. As disciplinas comuns (como CCO072) ficam no
-- mesmo semestre nos três cursos.
-- =====================================================================
CREATE TEMP TABLE tmp_grade (
  codigo   char(6),
  nome     varchar(100),
  ch_t     smallint,
  ch_p     smallint,
  semestre smallint,
  cursos   text
);
INSERT INTO tmp_grade VALUES
  -- 1º semestre
  ('CCO011', 'Algoritmos e Lógica de Programação',          40,  40, 1, 'CCO ESW ADS'),
  ('MDC118', 'Matemática Discreta',                          60,  20, 1, 'CCO ESW ADS'),
  ('CCO013', 'Arquitetura e Organização de Computadores',    60,  20, 1, 'CCO ESW ADS'),
  ('FGE101', 'Comunicação e Expressão',                      40,   0, 1, 'CCO ESW ADS'),
  ('MDC101', 'Cálculo I',                                    60,  20, 1, 'CCO ESW'),
  ('ADS011', 'Fundamentos de Sistemas de Informação',        40,   0, 1, 'ADS'),
  -- 2º semestre
  ('CCO021', 'Programação Estruturada',                      40,  40, 2, 'CCO ESW ADS'),
  ('MDC121', 'Álgebra Linear',                               60,  20, 2, 'CCO ESW'),
  ('MDC122', 'Cálculo II',                                   60,  20, 2, 'CCO'),
  ('FGE102', 'Ética, Cidadania e Sustentabilidade',          40,   0, 2, 'CCO ESW ADS'),
  ('CCO022', 'Sistemas Operacionais',                        60,  20, 2, 'CCO ESW ADS'),
  ('ESW021', 'Processos de Software',                        60,  20, 2, 'ESW ADS'),
  ('ADS021', 'Design de Interfaces',                         40,  40, 2, 'ADS'),
  -- 3º semestre
  ('CCO031', 'Programação Orientada a Objetos',              40,  40, 3, 'CCO ESW ADS'),
  ('CCO041', 'Estruturas de Dados',                          40,  40, 3, 'CCO ESW ADS'),
  ('MDC131', 'Probabilidade e Estatística',                  60,  20, 3, 'CCO ESW'),
  ('CCO032', 'Redes de Computadores',                        60,  20, 3, 'CCO ESW ADS'),
  ('MDC141', 'Cálculo Numérico',                             40,  40, 3, 'CCO'),
  ('ESW031', 'Engenharia de Requisitos',                     60,  20, 3, 'ESW ADS'),
  ('ADS031', 'Estatística Aplicada',                         40,  20, 3, 'ADS'),
  -- 4º semestre
  ('CCO061', 'Banco de Dados I',                             40,  40, 4, 'CCO ESW ADS'),
  ('CCO042', 'Linguagens Formais e Autômatos',               80,   0, 4, 'CCO'),
  ('CCO043', 'Teoria dos Grafos',                            60,  20, 4, 'CCO ESW'),
  ('CCO044', 'Programação Web',                              40,  40, 4, 'CCO ESW ADS'),
  ('FGE201', 'Metodologia Científica',                       40,   0, 4, 'CCO ESW ADS'),
  ('ESW041', 'Modelagem de Software com UML',                40,  40, 4, 'ESW ADS'),
  ('ADS041', 'Programação para Dispositivos Móveis',         40,  40, 4, 'ADS'),
  -- 5º semestre
  ('CCO072', 'Banco de Dados II',                            40,  40, 5, 'CCO ESW ADS'),
  ('CCO051', 'Análise e Projeto de Algoritmos',              60,  20, 5, 'CCO'),
  ('CCO052', 'Compiladores',                                 60,  20, 5, 'CCO'),
  ('CCO053', 'Segurança da Informação',                      60,  20, 5, 'CCO ESW ADS'),
  ('FGE202', 'Empreendedorismo e Inovação',                  40,   0, 5, 'CCO ESW ADS'),
  ('ESW051', 'Testes e Qualidade de Software',               40,  40, 5, 'ESW ADS'),
  ('ESW052', 'Arquitetura de Software',                      60,  20, 5, 'ESW'),
  ('ADS051', 'Projeto Integrador de Sistemas',               20,  60, 5, 'ADS'),
  -- 6º semestre
  ('CCO062', 'Inteligência Artificial',                      60,  20, 6, 'CCO'),
  ('CCO063', 'Sistemas Distribuídos',                        60,  20, 6, 'CCO ESW'),
  ('CCO064', 'Computação Gráfica',                           40,  40, 6, 'CCO'),
  ('CCO065', 'Teoria da Computação',                         80,   0, 6, 'CCO'),
  ('CCO066', 'Ciência de Dados',                             40,  40, 6, 'CCO ESW'),
  ('ESW061', 'Gerência de Projetos de Software',             60,  20, 6, 'ESW'),
  ('ESW062', 'DevOps e Integração Contínua',                 40,  40, 6, 'ESW'),
  ('ESW063', 'Interação Humano-Computador',                  40,  40, 6, 'ESW'),
  -- 7º semestre
  ('CCO071', 'Aprendizado de Máquina',                       40,  40, 7, 'CCO'),
  ('CCO073', 'Computação em Nuvem',                          40,  40, 7, 'CCO ESW'),
  ('CCO074', 'Big Data e Data Warehouse',                    40,  40, 7, 'CCO ESW'),
  ('CCO075', 'Computação e Sociedade',                       40,   0, 7, 'CCO ESW'),
  ('CCO091', 'Trabalho de Conclusão de Curso I',             40,   0, 7, 'CCO ESW'),
  ('ESW071', 'Manutenção e Evolução de Software',            40,  40, 7, 'ESW'),
  -- 8º semestre
  ('CCO092', 'Trabalho de Conclusão de Curso II',            40,   0, 8, 'CCO ESW'),
  ('CCO081', 'Processamento de Linguagem Natural',           40,  40, 8, 'CCO'),
  ('CCO082', 'Tópicos Avançados em Computação',              60,  20, 8, 'CCO ESW'),
  ('CCO083', 'Computação Paralela',                          40,  40, 8, 'CCO'),
  ('CCO084', 'Estágio Supervisionado',                        0, 160, 8, 'CCO ESW'),
  ('ESW081', 'Governança de TI',                             60,  20, 8, 'ESW'),
  ('ESW082', 'Tópicos Avançados em Engenharia de Software',  60,  20, 8, 'ESW');

INSERT INTO disciplina (codigo, nome, ch_teorica, ch_pratica)
SELECT codigo, nome, ch_t, ch_p FROM tmp_grade ORDER BY semestre, codigo;

UPDATE disciplina SET ementa =
  'Transações e controle de concorrência, índices e planos de execução, consultas '
  'avançadas (junções, CTEs recursivas, funções de janela), views, segurança, '
  'backup e recuperação em SGBD relacional.'
 WHERE codigo = 'CCO072';
UPDATE disciplina SET ementa =
  'Modelagem conceitual e lógica, modelo relacional, normalização e SQL.'
 WHERE codigo = 'CCO061';

-- string_to_array + unnest transforma 'CCO ESW ADS' em três linhas
INSERT INTO curriculo_disciplina (curriculo_id, disciplina_id, semestre_ideal, obrigatoria)
SELECT cu.id, d.id, g.semestre, true
  FROM tmp_grade g
 CROSS JOIN LATERAL unnest(string_to_array(g.cursos, ' ')) AS c(sigla)
  JOIN curso      co ON co.codigo = c.sigla
  JOIN curriculo  cu ON cu.curso_id = co.id AND cu.vigente
  JOIN disciplina d  ON d.codigo = g.codigo
 ORDER BY cu.id, g.semestre, d.codigo;


-- =====================================================================
-- 4. PRÉ-REQUISITOS (a árvore que as consultas recursivas percorrem)
-- Repare no "losango": CCO061 exige CCO041 e MDC118, e CCO041 também exige
-- MDC118. Na árvore de CCO072, MDC118 aparece por dois caminhos.
-- =====================================================================
INSERT INTO pre_requisito (disciplina_id, requisito_id)
SELECT d.id, r.id
  FROM (VALUES
    ('CCO021','CCO011'), ('MDC122','MDC101'), ('CCO022','CCO013'),
    ('CCO031','CCO021'), ('CCO041','CCO021'), ('CCO041','MDC118'),
    ('MDC131','MDC101'), ('CCO032','CCO022'), ('MDC141','MDC122'),
    ('MDC141','CCO021'), ('ESW031','ESW021'), ('CCO061','CCO041'),
    ('CCO061','MDC118'), ('CCO042','MDC118'), ('CCO043','CCO041'),
    ('CCO043','MDC118'), ('CCO044','CCO031'), ('ESW041','CCO031'),
    ('ESW041','ESW031'), ('ADS041','CCO031'), ('CCO072','CCO061'),
    ('CCO051','CCO043'), ('CCO051','MDC131'), ('CCO052','CCO042'),
    ('CCO052','CCO041'), ('CCO053','CCO032'), ('ESW051','ESW041'),
    ('ESW052','ESW041'), ('ADS051','CCO044'), ('ADS051','CCO061'),
    ('CCO062','CCO051'), ('CCO063','CCO032'), ('CCO063','CCO022'),
    ('CCO064','MDC121'), ('CCO064','CCO041'), ('CCO065','CCO042'),
    ('CCO066','CCO072'), ('CCO066','MDC131'), ('ESW061','ESW021'),
    ('ESW062','ESW051'), ('CCO071','CCO062'), ('CCO071','MDC131'),
    ('CCO073','CCO063'), ('CCO074','CCO072'), ('CCO074','CCO066'),
    ('CCO091','FGE201'), ('ESW071','ESW052'), ('CCO092','CCO091'),
    ('CCO081','CCO071'), ('CCO083','CCO063'), ('ESW081','ESW061'),
    ('ESW082','ESW071')
  ) AS p(disciplina, requisito)
  JOIN disciplina d ON d.codigo = p.disciplina
  JOIN disciplina r ON r.codigo = p.requisito
 ORDER BY d.id, r.id;


-- =====================================================================
-- 5. SIMULAÇÃO DOS 10 SEMESTRES
-- =====================================================================

-- ordem cronológica dos períodos (1 = 2022/1 ... 10 = 2026/2)
CREATE TEMP TABLE tmp_periodo AS
SELECT id, ano, semestre, data_inicio, data_fim, vigente,
       row_number() OVER (ORDER BY ano, semestre)::int AS ordem
  FROM periodo_letivo;

-- quem já foi aprovado em quê (consulta rápida durante a simulação)
CREATE TEMP TABLE tmp_aprovado (
  aluno_id      int,
  disciplina_id int,
  PRIMARY KEY (aluno_id, disciplina_id)
);

-- candidatos a matrícula no semestre que está sendo simulado
CREATE TEMP TABLE tmp_candidato (
  aluno_id       int,
  curso_id       int,
  turno          tp_turno,
  disciplina_id  int,
  semestre_ideal smallint
);

-- nomes para gerar alunos fictícios
CREATE TEMP TABLE tmp_nome (tipo char(1), i int, nome text);
INSERT INTO tmp_nome
SELECT 'P', ordinality::int, n FROM unnest(ARRAY[
  'Ana','Bruno','Carla','Daniel','Eduarda','Felipe','Gabriela','Gustavo','Helena','Igor',
  'Isabela','João','Júlia','Kauã','Larissa','Lucas','Mariana','Mateus','Natália','Otávio',
  'Paula','Pedro','Rafaela','Rafael','Sofia','Thiago','Vitória','Vinícius','Yasmin','Arthur',
  'Beatriz','Caio','Camila','Diego','Elisa','Fernando','Giovanna','Henrique','Lívia','Leonardo',
  'Manuela','Miguel','Nicole','Renato','Letícia','Samuel','Tatiane','Vítor','Alice','Bernardo',
  'Clara','Davi','Laura','Heitor','Lorena','Enzo','Valentina','Murilo','Luana','Cecília'
]) WITH ORDINALITY AS t(n)
UNION ALL
SELECT 'S', ordinality::int, n FROM unnest(ARRAY[
  'Silva','Santos','Oliveira','Souza','Lima','Pereira','Ferreira','Costa','Rodrigues','Almeida',
  'Nascimento','Carvalho','Araújo','Ribeiro','Rocha','Barbosa','Cardoso','Teixeira','Martins','Mendes',
  'Barros','Freitas','Moreira','Cavalcanti','Dias','Castro','Campos','Moura','Monteiro','Correia',
  'Vieira','Nunes','Ramos','Batista','Farias','Lopes','Melo','Rezende','Pires','Fonseca',
  'Andrade','Sales','Brandão','Machado','Siqueira','Queiroz','Tavares','Borges','Duarte','Peixoto'
]) WITH ORDINALITY AS t(n);

DO $$
DECLARE
  p          record;     -- o período sendo simulado
  v_seq_base int := 0;   -- numeração global dos alunos (para o CPF)
BEGIN
  FOR p IN SELECT * FROM tmp_periodo ORDER BY ordem LOOP

    -- -----------------------------------------------------------------
    -- 5.1 Calouros do período: 150 em CCO, 110 em ESW e 120 em ADS
    -- -----------------------------------------------------------------
    INSERT INTO aluno (matricula, nome, cpf, email, data_nascimento,
                       curso_id, periodo_ingresso_id, turno, situacao, criado_em)
    SELECT p.ano::text || p.semestre::text || lpad(g.seq::text, 5, '0'),
           pn.nome || ' ' || s1.nome || ' ' || s2.nome,
           pg_temp.gera_cpf(v_seq_base + g.seq),
           translate(lower(pn.nome || '.' || s2.nome), 'áàâãéêíóôõúüç', 'aaaaeeiooouuc')
             || '.' || p.ano::text || p.semestre::text || lpad(g.seq::text, 5, '0') || '@aluno.iesb.br',
           (p.data_inicio - make_interval(years => 17 + floor(pg_temp.rnd('idade' || p.ordem || '-' || g.seq) * 12)::int))::date
             - floor(pg_temp.rnd('dia' || p.ordem || '-' || g.seq) * 365)::int,
           c.id, p.id,
           CASE WHEN pg_temp.rnd('turno' || p.ordem || '-' || g.seq) < 0.4 THEN 'MATUTINO' ELSE 'NOTURNO' END::tp_turno,
           'ATIVO',
           -- cadastro feito na época do vestibular, ~1 mês antes do início das aulas
           (p.data_inicio - 30 + g.seq % 20) + time '10:00'
      FROM (SELECT gs AS seq,
                   CASE WHEN gs <= 150 THEN 'CCO' WHEN gs <= 260 THEN 'ESW' ELSE 'ADS' END AS sigla
              FROM generate_series(1, 380) AS gs) g
      JOIN curso c ON c.codigo = g.sigla
      JOIN tmp_nome pn ON pn.tipo = 'P' AND pn.i = 1 + floor(pg_temp.rnd('pn' || p.ordem || '-' || g.seq) * 60)::int
      JOIN tmp_nome s1 ON s1.tipo = 'S' AND s1.i = 1 + floor(pg_temp.rnd('s1' || p.ordem || '-' || g.seq) * 50)::int
      JOIN tmp_nome s2 ON s2.tipo = 'S' AND s2.i = 1 + floor(pg_temp.rnd('s2' || p.ordem || '-' || g.seq) * 50)::int
     ORDER BY g.seq;
    v_seq_base := v_seq_base + 380;

    -- -----------------------------------------------------------------
    -- 5.2 Quem pode se matricular em quê: disciplinas do currículo até o
    --     semestre em que o aluno está, ainda não aprovadas, e com TODOS os
    --     pré-requisitos aprovados. Prioridade para as atrasadas; máximo 6.
    -- -----------------------------------------------------------------
    TRUNCATE tmp_candidato;
    INSERT INTO tmp_candidato
    SELECT aluno_id, curso_id, turno, disciplina_id, semestre_ideal
      FROM (
        SELECT a.id AS aluno_id, a.curso_id, a.turno, cd.disciplina_id, cd.semestre_ideal,
               row_number() OVER (PARTITION BY a.id ORDER BY cd.semestre_ideal, cd.disciplina_id) AS prioridade
          FROM aluno a
          JOIN tmp_periodo pi          ON pi.id = a.periodo_ingresso_id
          JOIN curriculo cu            ON cu.curso_id = a.curso_id AND cu.vigente
          JOIN curriculo_disciplina cd ON cd.curriculo_id = cu.id
         WHERE a.situacao = 'ATIVO'
           AND pi.ordem <= p.ordem
           AND cd.semestre_ideal <= p.ordem - pi.ordem + 1
           -- ~3% dos veteranos não se matriculam no semestre (voltam depois)
           AND NOT (pi.ordem < p.ordem AND pg_temp.rnd('pula' || a.id || '-' || p.ordem) < 0.03)
           AND NOT EXISTS (SELECT 1 FROM tmp_aprovado ap
                            WHERE ap.aluno_id = a.id AND ap.disciplina_id = cd.disciplina_id)
           AND NOT EXISTS (SELECT 1 FROM pre_requisito pr
                            WHERE pr.disciplina_id = cd.disciplina_id
                              AND NOT EXISTS (SELECT 1 FROM tmp_aprovado ap2
                                               WHERE ap2.aluno_id = a.id
                                                 AND ap2.disciplina_id = pr.requisito_id))
      ) x
     WHERE prioridade <= 6;

    -- No período vigente, dois alunos de CCO (noturno) aptos a cursar
    -- Banco de Dados II ficam DE FORA de propósito: são os dois que vão
    -- disputar a última vaga na demonstração de concorrência (script 06).
    IF p.vigente THEN
      DELETE FROM tmp_candidato
       WHERE disciplina_id = (SELECT id FROM disciplina WHERE codigo = 'CCO072')
         AND aluno_id IN (SELECT c.aluno_id
                            FROM tmp_candidato c
                            JOIN curso cu ON cu.id = c.curso_id AND cu.codigo = 'CCO'
                           WHERE c.disciplina_id = (SELECT id FROM disciplina WHERE codigo = 'CCO072')
                             AND c.turno = 'NOTURNO'
                           ORDER BY c.aluno_id DESC
                           LIMIT 2);
    END IF;

    -- -----------------------------------------------------------------
    -- 5.3 Abre as turmas: uma por curso/turno/disciplina, e mais uma (B, C...)
    --     sempre que a anterior lota. Teóricas: 50 vagas; de laboratório: 40.
    --     Se sobrarem até 7 alunos, em vez de abrir uma turma minúscula a
    --     coordenação amplia as vagas da última turma.
    --     Código no padrão do IESB: curso + turno (D/N) + M + semestre + letra.
    -- -----------------------------------------------------------------
    INSERT INTO turma (codigo, disciplina_id, periodo_letivo_id, turno, vagas)
    SELECT cu.codigo || CASE g.turno WHEN 'MATUTINO' THEN 'D' ELSE 'N' END
                     || 'M' || g.semestre_ideal || chr(64 + s.i),
           g.disciplina_id, p.id, g.turno,
           CASE WHEN s.i = g.nt AND g.n > g.cap AND g.n % g.cap BETWEEN 1 AND 7
                THEN g.cap + g.n % g.cap ELSE g.cap END
      FROM (SELECT g0.*,
                   CASE WHEN g0.n > g0.cap AND g0.n % g0.cap BETWEEN 1 AND 7
                        THEN g0.n / g0.cap ELSE ceil(g0.n::numeric / g0.cap)::int END AS nt
              FROM (SELECT c.curso_id, c.turno, c.disciplina_id,
                           min(c.semestre_ideal) AS semestre_ideal,
                           count(*)::int AS n,
                           CASE WHEN d.ch_pratica BETWEEN 40 AND 80 THEN 40 ELSE 50 END AS cap
                      FROM tmp_candidato c
                      JOIN disciplina d ON d.id = c.disciplina_id
                     GROUP BY c.curso_id, c.turno, c.disciplina_id, d.ch_pratica) g0) g
      JOIN curso cu ON cu.id = g.curso_id
     CROSS JOIN LATERAL generate_series(1, g.nt) AS s(i)
     ORDER BY g.disciplina_id, cu.codigo, g.turno, s.i;

    -- -----------------------------------------------------------------
    -- 5.4 Matrículas: cada candidato vai para a turma do seu curso/turno,
    --     enchendo a A antes de passar para a B. A data cai na janela de
    --     matrícula (janeiro ou julho). Inseridas em ordem cronológica.
    -- -----------------------------------------------------------------
    INSERT INTO matricula (aluno_id, turma_id, status, data_matricula)
    SELECT x.aluno_id, t.id,
           CASE WHEN p.vigente THEN 'MATRICULADO' ELSE 'CONCLUIDO' END::tp_status_matricula,
           x.data_matricula
      FROM (SELECT c.*, cu.codigo AS sigla,
                   row_number() OVER (PARTITION BY c.curso_id, c.turno, c.disciplina_id
                                      ORDER BY pg_temp.rnd('fila' || c.aluno_id || '-' || c.disciplina_id || '-' || p.ordem),
                                               c.aluno_id) AS rn,
                   count(*)     OVER (PARTITION BY c.curso_id, c.turno, c.disciplina_id)::int AS n,
                   CASE WHEN d.ch_pratica BETWEEN 40 AND 80 THEN 40 ELSE 50 END AS cap,
                   make_timestamptz(p.ano, CASE p.semestre WHEN 1 THEN 1 ELSE 7 END, 8, 8, 0, 0,
                                    'America/Sao_Paulo')
                     + make_interval(secs => floor(pg_temp.rnd('quando' || c.aluno_id || '-' || p.ordem) * 26 * 86400)
                                             + floor(pg_temp.rnd('hora' || c.aluno_id || '-' || c.disciplina_id || '-' || p.ordem) * 3600)
                                    ) AS data_matricula
              FROM tmp_candidato c
              JOIN curso cu     ON cu.id = c.curso_id
              JOIN disciplina d ON d.id = c.disciplina_id) x
      JOIN turma t
        ON t.periodo_letivo_id = p.id
       AND t.disciplina_id = x.disciplina_id
       AND t.codigo = x.sigla || CASE x.turno WHEN 'MATUTINO' THEN 'D' ELSE 'N' END
                     || 'M' || x.semestre_ideal
                     || chr(65 + least((x.rn - 1) / x.cap,
                                       CASE WHEN x.n > x.cap AND x.n % x.cap BETWEEN 1 AND 7
                                            THEN x.n / x.cap ELSE ceil(x.n::numeric / x.cap)::int END - 1)::int)
     ORDER BY x.data_matricula, x.aluno_id, x.disciplina_id;

    -- -----------------------------------------------------------------
    -- 5.5 Histórico. Cada aluno tem uma "aptidão" e cada disciplina uma
    --     "dificuldade"; a nota é aptidão + dificuldade + ruído.
    --     Semestres passados: A1, A2, P3 (quando cabe), frequência e situação.
    --     Semestre vigente (2026/2): só a A1 foi lançada; situação CURSANDO.
    -- -----------------------------------------------------------------
    INSERT INTO historico (matricula_id, nota_a1, nota_a2, nota_p3, frequencia, situacao, atualizado_em)
    SELECT n.matricula_id, n.a1, n.a2, n.p3, n.freq,
           CASE
             WHEN p.vigente THEN 'CURSANDO'
             WHEN n.freq < 75 THEN 'REPROVADO_FALTA'
             WHEN (CASE WHEN n.p3 IS NULL THEN round(0.4 * n.a1 + 0.6 * n.a2, 2)
                        ELSE round(greatest(0.4 * n.a1 + 0.6 * n.a2,
                                            0.4 * n.p3 + 0.6 * n.a2,
                                            0.4 * n.a1 + 0.6 * n.p3), 2) END) >= 5 THEN 'APROVADO'
             ELSE 'REPROVADO_NOTA'
           END::tp_situacao_historico,
           CASE WHEN p.vigente THEN (p.data_inicio + 62) + time '18:30'
                ELSE p.data_fim + time '18:30' END
      FROM (
        SELECT b.matricula_id, b.a1,
               CASE WHEN p.vigente THEN NULL ELSE b.a2 END AS a2,
               CASE WHEN NOT p.vigente AND b.freq >= 75
                         AND 0.4 * b.a1 + 0.6 * b.a2 < 5
                         AND pg_temp.rnd('fazp3' || b.matricula_id) < 0.75
                    THEN least(10, greatest(0, round((b.mu + 0.6 + (pg_temp.rnd('p3' || b.matricula_id) - 0.5) * 4)::numeric, 1)))
               END AS p3,
               b.freq
          FROM (
            SELECT m.id AS matricula_id, k.mu,
                   least(10, greatest(0, round((k.mu + (pg_temp.rnd('a1' || m.id) - 0.5) * 4.4)::numeric, 1))) AS a1,
                   least(10, greatest(0, round((k.mu + (pg_temp.rnd('a2' || m.id) - 0.5) * 4.4)::numeric, 1))) AS a2,
                   least(100, greatest(0, round((100 - 30 * pg_temp.rnd('f1' || m.id) ^ 4
                                                     - 28 * (1 - k.apt) * pg_temp.rnd('f2' || m.id) ^ 3)::numeric, 1))) AS freq
              FROM matricula m
              JOIN turma t      ON t.id = m.turma_id AND t.periodo_letivo_id = p.id
              JOIN disciplina d ON d.id = t.disciplina_id
             CROSS JOIN LATERAL (
               -- dificuldade por área: Matemática pesa mais, Formação Geral menos
               SELECT pg_temp.rnd('apt' || m.aluno_id) AS apt,
                      4.0 + 5.4 * pg_temp.rnd('apt' || m.aluno_id)
                          + CASE left(d.codigo, 3) WHEN 'MDC' THEN -0.9 WHEN 'FGE' THEN 0.7
                                                   WHEN 'CCO' THEN -0.3 ELSE 0.1 END
                          + (pg_temp.rnd('dif' || t.disciplina_id) - 0.5) * 0.8 AS mu
             ) k
          ) b
      ) n
     ORDER BY n.matricula_id;

    -- -----------------------------------------------------------------
    -- 5.6 Fim do semestre (só nos já encerrados): registra aprovações,
    --     forma quem concluiu o currículo e aplica a evasão (~4,5%).
    -- -----------------------------------------------------------------
    IF NOT p.vigente THEN
      INSERT INTO tmp_aprovado (aluno_id, disciplina_id)
      SELECT m.aluno_id, t.disciplina_id
        FROM matricula m
        JOIN turma t     ON t.id = m.turma_id AND t.periodo_letivo_id = p.id
        JOIN historico h ON h.matricula_id = m.id
       WHERE h.situacao = 'APROVADO'
      ON CONFLICT DO NOTHING;

      UPDATE aluno a
         SET situacao = 'FORMADO'
       WHERE a.situacao = 'ATIVO'
         AND a.curso_id IS NOT NULL
         AND NOT EXISTS (SELECT 1
                           FROM curriculo cu
                           JOIN curriculo_disciplina cd ON cd.curriculo_id = cu.id
                          WHERE cu.curso_id = a.curso_id AND cu.vigente
                            AND NOT EXISTS (SELECT 1 FROM tmp_aprovado ap
                                             WHERE ap.aluno_id = a.id
                                               AND ap.disciplina_id = cd.disciplina_id));

      UPDATE aluno a
         SET situacao = CASE WHEN pg_temp.rnd('evasao' || a.id || '-' || p.ordem) < 0.02
                             THEN 'DESLIGADO' ELSE 'TRANCADO' END::tp_situacao_aluno
       WHERE a.situacao = 'ATIVO'
         AND pg_temp.rnd('evasao' || a.id || '-' || p.ordem) < 0.045;
    END IF;

    RAISE NOTICE 'Período %/% simulado', p.ano, p.semestre;
  END LOOP;
END $$;


-- =====================================================================
-- 6. TURMAS SEM ALUNOS no período vigente (optativas no vespertino).
-- Existem para a junção externa (LEFT JOIN) ter o que mostrar: turma com
-- zero matrículas só aparece no resultado se a junção for externa.
-- =====================================================================
INSERT INTO turma (codigo, disciplina_id, periodo_letivo_id, turno, vagas)
SELECT v.codigo, d.id, p.id, 'VESPERTINO', v.vagas
  FROM (VALUES ('CCOVM7A', 'CCO075', 40),
               ('CCOVM5A', 'FGE202', 40),
               ('ESWVM8A', 'CCO082', 30)) AS v(codigo, disciplina, vagas)
  JOIN disciplina d     ON d.codigo = v.disciplina
  JOIN periodo_letivo p ON p.vigente
 ORDER BY v.codigo;


-- =====================================================================
-- 7. ALUNOS ESPECIAIS: cadastrados, sem curso e sem matrícula
-- (o caso "(0,1)" do relacionamento aluno-curso: a FK curso_id é nula)
-- =====================================================================
INSERT INTO aluno (matricula, nome, cpf, email, data_nascimento, curso_id, periodo_ingresso_id, turno, situacao, criado_em)
SELECT '2026299' || lpad(v.n::text, 3, '0'), v.nome, pg_temp.gera_cpf(900000 + v.n),
       v.email, v.nasc, NULL, p.id, 'NOTURNO', 'ATIVO', TIMESTAMPTZ '2026-08-10 14:00:00-03'
  FROM (VALUES (1, 'Karina Melo Duarte',       'karina.duarte.2026299001@aluno.iesb.br',  DATE '2001-03-14'),
               (2, 'Otávio Prado Lins',        'otavio.lins.2026299002@aluno.iesb.br',    DATE '1998-11-02'),
               (3, 'Renata Aguiar Coelho',     'renata.coelho.2026299003@aluno.iesb.br',  DATE '2003-07-21'),
               (4, 'Sérgio Lacerda Bastos',    'sergio.bastos.2026299004@aluno.iesb.br',  DATE '1995-01-30')
       ) AS v(n, nome, email, nasc)
  JOIN periodo_letivo p ON p.vigente
 ORDER BY v.n;


-- =====================================================================
-- 8. SALAS E HORÁRIOS (sem choque: o EXCLUDE da tabela confere)
-- Faixas do IESB: matutino 08:00-09:40 e 10:00-11:40; vespertino
-- 14:00-15:40 e 16:00-17:40; noturno 19:00-20:40 e 20:50-22:30.
-- Cada sala recebe 5 turmas por turno, cada turma com dois encontros
-- semanais em dias diferentes: os 10 encaixes (5 dias x 2 faixas) da sala
-- ficam todos ocupados sem sobreposição.
-- =====================================================================
DO $$
DECLARE
  v_salas int;
  v_labs  int;
BEGIN
  -- quantas salas/laboratórios o período mais cheio exige
  SELECT max(ceil(n / 5.0)) FILTER (WHERE NOT lab),
         max(ceil(n / 5.0)) FILTER (WHERE lab)
    INTO v_salas, v_labs
    FROM (SELECT t.periodo_letivo_id, t.turno, (d.ch_pratica BETWEEN 40 AND 80) AS lab, count(*) AS n
            FROM turma t JOIN disciplina d ON d.id = t.disciplina_id
           GROUP BY 1, 2, 3) x;

  INSERT INTO sala (codigo, bloco, capacidade, tipo)
  SELECT chr(65 + (i - 1) / 20) || '-' || (101 + (i - 1) % 20), chr(65 + (i - 1) / 20), 60, 'SALA'
    FROM generate_series(1, v_salas) AS i
   ORDER BY i;

  INSERT INTO sala (codigo, bloco, capacidade, tipo)
  SELECT 'LAB-' || lpad(i::text, 2, '0'), 'L', 50, 'LABORATORIO'
    FROM generate_series(1, v_labs) AS i
   ORDER BY i;

  -- um auditório que não recebe turma regular (aparece nas consultas de uso de sala)
  INSERT INTO sala (codigo, bloco, capacidade, tipo) VALUES ('AUD-01', 'Z', 200, 'AUDITORIO');

  INSERT INTO turma_horario (turma_id, periodo_letivo_id, dia_semana, hora_inicio, hora_fim, sala_id)
  SELECT t.id, t.periodo_letivo_id, e.dia, f.ini, f.fim, s.id
    FROM (SELECT t.id, t.periodo_letivo_id, t.turno,
                 CASE WHEN d.ch_pratica BETWEEN 40 AND 80 THEN 'LABORATORIO' ELSE 'SALA' END::tp_tipo_sala AS tipo,
                 (row_number() OVER (PARTITION BY t.periodo_letivo_id, t.turno, (d.ch_pratica BETWEEN 40 AND 80)
                                     ORDER BY t.id) - 1)::int AS k
            FROM turma t JOIN disciplina d ON d.id = t.disciplina_id) t
    JOIN (SELECT id, tipo, (row_number() OVER (PARTITION BY tipo ORDER BY id) - 1)::int AS idx
            FROM sala WHERE tipo <> 'AUDITORIO') s
      ON s.tipo = t.tipo AND s.idx = t.k / 5
   CROSS JOIN LATERAL (VALUES ((t.k % 5) + 1, 1),
                              (((t.k % 5) + 2) % 5 + 1, 2)) AS e(dia, faixa)
   CROSS JOIN LATERAL (
     SELECT CASE t.turno WHEN 'MATUTINO'   THEN CASE e.faixa WHEN 1 THEN time '08:00' ELSE time '10:00' END
                         WHEN 'VESPERTINO' THEN CASE e.faixa WHEN 1 THEN time '14:00' ELSE time '16:00' END
                         ELSE                   CASE e.faixa WHEN 1 THEN time '19:00' ELSE time '20:50' END
            END AS ini,
            CASE t.turno WHEN 'MATUTINO'   THEN CASE e.faixa WHEN 1 THEN time '09:40' ELSE time '11:40' END
                         WHEN 'VESPERTINO' THEN CASE e.faixa WHEN 1 THEN time '15:40' ELSE time '17:40' END
                         ELSE                   CASE e.faixa WHEN 1 THEN time '20:40' ELSE time '22:30' END
            END AS fim
   ) f
   ORDER BY t.id, e.dia;
END $$;


-- =====================================================================
-- 9. ESTATÍSTICAS PARA O OTIMIZADOR E CONFERÊNCIA DO VOLUME
-- ANALYZE atualiza as estatísticas que o planejador usa para escolher o
-- plano (seq scan x índice). Sem isso, ele estima errado logo após a carga.
-- =====================================================================
ANALYZE;

SELECT item, quantidade, exigencia
  FROM (          SELECT 1 AS ordem, 'alunos' AS item, count(*) AS quantidade, 'mínimo exigido: 100' AS exigencia FROM aluno
        UNION ALL SELECT 2, 'turmas',      count(*), 'mínimo exigido: 6'   FROM turma
        UNION ALL SELECT 3, 'matrículas',  count(*), 'mínimo exigido: 300' FROM matricula
        UNION ALL SELECT 4, 'históricos',  count(*), '-'                   FROM historico
        UNION ALL SELECT 5, 'disciplinas', count(*), '-'                   FROM disciplina
        UNION ALL SELECT 6, 'salas',       count(*), '-'                   FROM sala
        UNION ALL SELECT 7, 'horários',    count(*), '-'                   FROM turma_horario) x
 ORDER BY ordem;
