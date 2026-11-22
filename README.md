# Projeto Acadêmico — Sistema de Matrícula Acadêmica

## O que tem nesta pasta

| Arquivo / pasta | Para que serve |
|---|---|
| `docker-compose.yml` | Diz ao Docker como criar o banco: nome do contêiner, porta, senha, onde guardar os dados. |
| `Dockerfile` | Monta a imagem: PostgreSQL 17 oficial + os scripts da pasta `sql/`. |
| `sql/` | Os scripts do projeto, numerados na ordem em que rodam. |
| `evidencias/EXPLAIN_ANALYZE.md` | O EXPLAIN antes e depois de cada índice, com o ganho medido. |
| `AUTORES.md` | A frente de cada integrante. |

| Script | O que faz |
|---|---|
| `01_ddl.sql` | Cria as tabelas, tipos, domínios, chaves e restrições de integridade. |
| `02_carga.sql` | Carrega os dados (alunos, turmas, matrículas, histórico). |
| `03_consultas.sql` | As 10 consultas do Marco 1. |
| `04_views.sql` | 3 views e 1 materialized view. |
| `05_indices.sql` | Os índices, com EXPLAIN antes e depois. |
| `06_transacoes.sql` | A disputa pela última vaga e as duas correções. |
| `07_seguranca.sql` | Papéis (aluno, secretaria, coordenacao), GRANT/REVOKE e segurança por linha. |
| `08_operacao.sql` | A view de inventário, usada para conferir o backup. |
| `09_bonus_jsonb.sql` | Bônus: auditoria em JSONB com índice GIN. |

---

## Antes de começar

1. **Abra o Docker Desktop** e espere o ícone da baleia ficar parado (verde). Sem ele aberto, nenhum comando `docker` funciona.
2. **Extraia a pasta do zip** (botão direito no zip → *Extrair tudo*). Não rode de dentro do zip.
3. **Na primeira vez precisa de internet**: o Docker baixa o PostgreSQL 17 e o pgAdmin.

---

## Parte 1 — Subir o banco pelo cmd

### Passo 1: abrir o cmd dentro da pasta do projeto

Abra a pasta `projeto_bd2` no Explorador de Arquivos, clique na **barra de endereço** (onde aparece o caminho da pasta), apague o que estiver escrito, digite `cmd` e aperte **Enter**.

forma: abra o cmd pelo menu Iniciar e vá até a pasta com `cd /d "C:\caminho\da\pasta\projeto_bd2"`.

### Passo 2: conferir se o Docker está respondendo

```
docker ps
```

> **Para que serve:** lista os contêineres ligados. Se aparecer uma tabela (mesmo vazia), o Docker está funcionando. Se aparecer erro, o Docker Desktop está fechado.

### Passo 3: criar e ligar o banco

```
docker compose up -d --build --wait
```

> **Para que serve cada parte:**
> - `docker compose up` — cria e liga o que está descrito no `docker-compose.yml`.
> - `-d` — roda em segundo plano, e o cmd fica livre para você continuar.
> - `--build` — monta a imagem do projeto (PostgreSQL 17 + os scripts da pasta `sql/`).
> - `--wait` — só devolve o cmd quando o banco estiver **pronto** para uso.

Na primeira vez leva de 1 a 3 minutos, porque baixa o PostgreSQL e roda os scripts 01 a 09. Quando terminar, aparece algo como `Container bd2_projeto_db Healthy`. Nas próximas vezes sobe em segundos, com os dados como você deixou.

### Passo 4: conferir se o banco está ligado

```
docker ps
```

> **Para que serve:** tem que aparecer uma linha com `bd2_projeto_db` e o status `Up ... (healthy)`. *healthy* quer dizer que o banco terminou de ser criado e está aceitando conexões.

### Passo 5 (opcional): conferir os dados pelo próprio cmd

```
docker exec bd2_projeto_db psql -U postgres -d iesb -c "SELECT * FROM vw_inventario;"
```

> **Para que serve:** `docker exec` roda um comando **dentro** do contêiner. Aqui ele abre o `psql` no banco `iesb` e mostra quantas linhas tem cada tabela. Se aparecer a lista de tabelas com os números, o banco está pronto.

---

## Parte 2 — Abrir no pgAdmin pelo navegador

Nesse modo, o pgAdmin também roda dentro do Docker e você usa pelo Chrome (ou outro navegador).

### Passo B1: ligar o pgAdmin

No cmd, digite tudo numa linha só:

```
docker run -d --name pgadmin -p 5050:80 -e PGADMIN_DEFAULT_EMAIL=aluno@iesb.br -e PGADMIN_DEFAULT_PASSWORD=iesb2026 dpage/pgadmin4
```

> **Para que serve cada parte:**
> - `docker run -d` — cria e liga um contêiner em segundo plano.
> - `--name pgadmin` — dá o nome `pgadmin` a ele, para ligar e desligar depois.
> - `-p 5050:80` — o pgAdmin fica no endereço `localhost:5050` do seu computador.
> - `-e PGADMIN_DEFAULT_EMAIL=...` e `-e PGADMIN_DEFAULT_PASSWORD=...` — o login e a senha para entrar no pgAdmin.
> - `dpage/pgadmin4` — a imagem oficial do pgAdmin.

Na primeira vez ele baixa o pgAdmin e pode demorar alguns minutos.

**Se aparecer `The container name "/pgadmin" is already in use`**, você já criou o pgAdmin antes (por exemplo, na aula de BD I). Então só ligue ele:

```
docker start pgadmin
```

### Passo B2: abrir no navegador

Digite na barra de endereço do navegador:

```
http://localhost:5050
```

Se não abrir, espere 1 minuto e aperte F5. Entre com:

| Campo | Valor |
|---|---|
| E-mail | `aluno@iesb.br` |
| Senha | `iesb2026` |

### Passo B3: cadastrar o banco do projeto

1. Na lateral esquerda, clique com o botão direito em **Servers** → **Register** → **Server...**
2. Aba **General**: em **Name**, escreva `bd2_projeto` (é só um apelido).
3. Aba **Connection**: preencha exatamente assim:

| Campo | Valor |
|---|---|
| Host name/address | `host.docker.internal` |
| Port | `5434` |
| Maintenance database | `iesb` |
| Username | `postgres` |
| Password | `iesb2026` |

4. Ligue a opção **Save password**.
5. Clique em **Save**.

> **Por que `host.docker.internal` e não `localhost`:** aqui o pgAdmin está dentro de um contêiner. Para ele, `localhost` é o próprio contêiner do pgAdmin, onde não tem banco nenhum. `host.docker.internal` é o jeito de o contêiner chegar no seu computador, onde a porta 5434 leva ao banco.

### Passo B4: ver as tabelas e rodar uma consulta

1. Abra **Servers → bd2_projeto → Databases → iesb → Schemas → academico → Tables**. Aparece também o banco `postgres`, mas o do projeto é o **`iesb`**.
2. Clique com o botão direito em **iesb** → **Query Tool**.
3. Digite `SELECT * FROM vw_inventario;` e aperte **F5** (ou o botão ▶).

---

## Parte 3 — Abrir no pgAdmin aplicativo (instalado no Windows)

Nesse modo, o pgAdmin é um programa instalado no computador. Se ainda não tiver, baixe em **pgadmin.org** → *Download* → *Windows* e instale normalmente.

1. Abra o **pgAdmin 4** pelo menu Iniciar. Na primeira vez ele pode pedir para criar uma senha mestra (é só do pgAdmin, escolha uma e anote).
2. Clique com o botão direito em **Servers** → **Register** → **Server...**
3. Aba **General**: **Name** = `bd2_projeto`.
4. Aba **Connection**:

| Campo | Valor |
|---|---|
| Host name/address | `localhost` |
| Port | `5434` |
| Maintenance database | `iesb` |
| Username | `postgres` |
| Password | `iesb2026` |

5. Ligue **Save password** e clique em **Save**.
6. Para ver as tabelas e rodar consultas, siga o **Passo B4**.

> **Por que aqui é `localhost`:** o aplicativo roda direto no Windows, e não dentro do Docker. Para ele, `localhost` é o seu computador, e a porta 5434 leva ao banco.

**Resumo da diferença:**

| | pgAdmin no navegador | pgAdmin aplicativo |
|---|---|---|
| Onde roda | Dentro do Docker | Instalado no Windows |
| Como abre | `http://localhost:5050` | Menu Iniciar → pgAdmin 4 |
| Host para o banco | `host.docker.internal` | `localhost` |
| Porta do banco | `5434` | `5434` |

---

## Parte 4 — Desligar

Feche o pgAdmin (a aba do navegador ou o aplicativo). Depois, no cmd, **dentro da pasta do projeto**:

### Passo D1: desligar o pgAdmin do navegador (se você usou)

```
docker stop pgadmin
```

> **Para que serve:** desliga o contêiner do pgAdmin. O login e o servidor cadastrado ficam salvos para a próxima vez.

### Passo D2: desligar o banco

```
docker compose down
```

> **Para que serve:** pede ao PostgreSQL para parar com calma (gravando tudo no disco) e remove o contêiner. **Os dados não somem:** ficam guardados no volume `dados_bd2` do Docker.

### Passo D3: fechar o Docker Desktop (opcional)

Clique com o botão direito na baleia, perto do relógio → **Quit Docker Desktop**. Isso libera a memória do computador.

### Na próxima vez

Com o Docker Desktop aberto e o cmd na pasta do projeto:

```
docker compose up -d --build --wait
docker start pgadmin
```

O primeiro liga o banco, com os dados como você deixou. O segundo liga o pgAdmin do navegador (só se você usa ele). Depois é só abrir `http://localhost:5050` ou o aplicativo.

---

## Recriar o banco do zero

Use só se quiser voltar o banco ao estado original (por exemplo, se algo deu errado):

```
docker compose down -v
docker compose up -d --build --wait
```

> **Para que serve:** o `-v` **apaga o volume** com os dados. Na subida seguinte, o Docker roda os scripts 01 a 09 de novo e cria o banco do início.

---

## Backup e restauração

Tudo no cmd, dentro da pasta do projeto, com o banco ligado.

### Fazer o backup

```
docker exec bd2_projeto_db pg_dumpall -U postgres --globals-only -f /tmp/papeis.sql
docker exec bd2_projeto_db pg_dump -U postgres -d iesb -Fc -f /tmp/iesb.dump
docker cp bd2_projeto_db:/tmp/papeis.sql papeis.sql
docker cp bd2_projeto_db:/tmp/iesb.dump iesb.dump
```

> **Para que serve:**
> - `pg_dumpall --globals-only` — salva os papéis e as senhas (aluno, secretaria, coordenacao). Eles pertencem ao servidor, e não ao banco, por isso o `pg_dump` não os leva.
> - `pg_dump -Fc` — salva o banco `iesb` inteiro (tabelas, dados, índices, views, funções, permissões), num arquivo compactado.
> - `docker cp` — copia os dois arquivos de dentro do contêiner para a pasta do projeto.

### Restaurar

```
docker cp iesb.dump bd2_projeto_db:/tmp/iesb.dump
docker exec bd2_projeto_db dropdb -U postgres --force iesb
docker exec bd2_projeto_db pg_restore -U postgres -d postgres --create --exit-on-error /tmp/iesb.dump
```

> **Para que serve:**
> - `docker cp` — leva o arquivo de backup para dentro do contêiner.
> - `dropdb --force` — apaga o banco `iesb`, derrubando quem estiver conectado (inclusive o pgAdmin).
> - `pg_restore --create` — recria o banco `iesb` com as configurações dele e devolve todo o conteúdo.

Se for restaurar num servidor novo, onde os papéis ainda não existem, rode isto **antes** do `pg_restore`:

```
docker cp papeis.sql bd2_projeto_db:/tmp/papeis.sql
docker exec bd2_projeto_db psql -U postgres -d postgres -f /tmp/papeis.sql
```

### Conferir se voltou igual

Rode antes do backup e depois da restauração:

```
docker exec bd2_projeto_db psql -U postgres -d iesb -c "SELECT * FROM vw_inventario;"
```

As contagens e as assinaturas (md5) de cada tabela têm de ser **iguais** nas duas vezes.

---

## Deu problema?

| O que aparece | O que fazer |
|---|---|
| `docker: command not found` ou `cannot connect to the Docker daemon` | O Docker Desktop está fechado. Abra e espere a baleia ficar verde. |
| `no configuration file provided: not found` | O cmd não está dentro da pasta do projeto. Volte ao Passo 1. |
| `port is already allocated` ao subir o banco | Outro programa usa a porta 5434. No `docker-compose.yml`, troque `"5434:5432"` por `"5435:5432"` e use 5435 no pgAdmin. |
| `port is already allocated` ao ligar o pgAdmin | Troque `-p 5050:80` por `-p 5051:80` e abra `http://localhost:5051`. |
| `The container name "/pgadmin" is already in use` | O pgAdmin já existe. Rode só `docker start pgadmin`. |
| pgAdmin: `Unable to connect to server` / `Connection refused` | Confira o host (`host.docker.internal` no navegador, `localhost` no aplicativo), a porta 5434 e se o banco está ligado (`docker ps`). |
| `password authentication failed` | A senha é `iesb2026`, tudo minúsculo. |
| `relation "aluno" does not exist` | A Query Tool está no banco `postgres`. Abra a Query Tool clicando com o botão direito no banco **`iesb`**. |
| O banco ficou "pela metade" depois de um erro | Recrie do zero (seção acima). |
