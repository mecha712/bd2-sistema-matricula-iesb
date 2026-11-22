# =====================================================================
# Imagem do Projeto BD2 (CCO072) - IESB 2026/2
# PostgreSQL 17 oficial + os scripts da pasta sql/ embutidos.
#
# Tudo o que esta em /docker-entrypoint-initdb.d/ roda SOZINHO, em ordem
# (01, 02, ... 09), na PRIMEIRA vez que o conteiner sobe com o volume
# vazio. Nas vezes seguintes o banco ja existe e nada roda de novo.
# =====================================================================
FROM postgres:17

COPY sql/ /docker-entrypoint-initdb.d/
