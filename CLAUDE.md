# Play Ahead Installer

## O que é este projeto

Script de instalação em bash, mantido pela Play Ahead, que sobe uma stack do
Mautic 7 em Docker numa VPS. Nasce como material de apoio de um vídeo do
YouTube que ensina a instalar o Mautic 7, e depois vira a base de instaladores
para outras ferramentas (Chatwoot, Typebot, Evolution API).

O mesmo script é usado nas instalações do serviço pago da agência, então ele
precisa funcionar sem intervenção manual.

Público-alvo: pessoa iniciante em Linux, seguindo um tutorial em vídeo, numa VPS
Ubuntu recém-criada na Hetzner, DigitalOcean ou Contabo.

São dois instaladores, e o tutorial mostra os dois. Primeiro a base, uma vez
por VPS:

    curl -sL https://get.playahead.com.br/base -o base.sh
    less base.sh
    sudo bash base.sh

Depois a ferramenta:

    curl -sL https://get.playahead.com.br/mautic7 -o mautic7.sh
    less mautic7.sh
    sudo bash mautic7.sh

O tutorial mostra o download separado da execução de propósito, para ensinar a
pessoa a ler um script antes de rodar.

## Distribuição e build

O código-fonte é modular (`lib/*.sh`), mas o que é publicado são **arquivos
únicos**. Um script baixado sozinho por `curl` não consegue dar `source` em
arquivos que não existem na VPS.

`build.sh` concatena as libs de cada alvo e gera três artefatos:

    dist/base.sh        get.playahead.com.br/base
    dist/mautic7.sh     get.playahead.com.br/mautic7
    dist/playahead.sh   get.playahead.com.br  (menu)

Cada artefato leva só as libs que usa, e é autocontido: toda função chamada
está definida no próprio arquivo. O que eles compartilham é código-fonte, não
arquivo publicado.

**A ordem de build importa:** o menu embute os outros dois, então eles têm de
existir antes. É a única dependência entre alvos.

**Os três ficam versionados no git.** Qualquer pessoa precisa conseguir
abrir o GitHub e auditar exatamente o mesmo conteúdo que o `curl` baixou. Um
artefato de build que só existe no servidor de distribuição derruba a promessa
do `less mautic7.sh`.

O topo do arquivo gerado carrega, obrigatoriamente:

    # Versão: 0.1.0
    # Build:  2026-08-26T14:03:11Z
    # Fonte:  https://github.com/play-ahead/playahead-installer

Motivo: quando aparecer comentário no vídeo dizendo que não funcionou, a
primeira pergunta é qual versão a pessoa rodou. Sem isso não há suporte
possível. `--version` imprime os mesmos dados e sai.

A versão vive numa variável única no fonte; o `build.sh` a propaga para o
cabeçalho gerado. Regenerar o `dist/` faz parte do commit, não é passo separado.

`./build.sh --check` verifica se o `dist/` está em dia com o `lib/` sem
reescrever nada, e sai com 1 quando está defasado. Serve para CI e para
hook de commit, já que a regra é o artefato ser versionado junto.

O build não reescreve o arquivo quando só a data de build mudaria. Um diff
que altera apenas o timestamp faz o revisor procurar uma alteração que não
existe.

O template do compose vai embutido como heredoc citado, não em base64: quem
dá `less mautic7.sh` precisa conseguir ler o compose que será instalado. O
build confere que o template embutido é byte a byte igual ao original.

### Nome do artefato, versão e tags

O artefato é `dist/mautic7.sh`, com o nome da ferramenta, e não
`dist/install.sh`. O repositório reúne os instaladores de várias ferramentas,
e um `install.sh` ao lado de um `chatwoot.sh` faria qualquer pessoa perguntar
o que o primeiro instala. O `templates/` já usava essa convenção.

Isso foi resolvido antes do lançamento de propósito: é a única parte desta
decisão que fica mais cara com o tempo. Depois de publicado, mudar o nome
significa atualizar o redirecionamento, deixar um 404 para quem já tinha o
link, e conviver com tags antigas apontando para o caminho velho.

`PA_VERSAO` é a versão **deste** instalador, não do repositório: com vários no
mesmo lugar, cada um versiona por conta própria. Por isso as tags levam o
prefixo da ferramenta — `mautic7-v0.1.0`. Uma tag `v0.1.0` solta ficaria
ambígua no dia em que o segundo instalador entrar, e aí conviveriam dois
formatos.

O script diz qual ferramenta instala, no cabeçalho de tela, no cabeçalho do
artefato e no `--version`. O nome vive em `PA_FERRAMENTA`, em `lib/main.sh`, e
não em `lib/ui.sh`: o `ui.sh` é genérico e vai ser reaproveitado pelos
próximos. Com vários instaladores, a primeira pergunta do suporte deixa de ser
só "qual versão" e passa a ser "qual instalador".

**O que deliberadamente não foi feito**, para não preparar o projeto para
instaladores que ainda não existem:

- Diretório `targets/`, manifesto de alvos, ou laço sobre uma lista externa. Os
  dois alvos são declarados lado a lado no `build.sh`; o terceiro se acrescenta
  copiando cinco linhas.
- Qualquer abstração de "ferramenta" além do que a separação da base exigiu.

## Arquitetura: base e ferramentas

São dois tipos de instalador, e a regra que os separa é uma: **a base é dona de
tudo que é compartilhado entre ferramentas; o instalador de ferramenta é dono
do que só serve a ela.**

| | `base.sh` | `mautic7.sh` |
|---|---|---|
| Checagens de máquina | sim | sim |
| Swap | **sim** | não |
| Docker e Compose | **instala** | só detecta |
| Rede do proxy, Traefik | **instala** | só detecta |
| Portainer | **sim** | não |
| Stack do Mautic | não | sim |

Assim os próximos instaladores herdam a base em vez de recriá-la, e a
instalação do Docker existe num lugar só.

### Os dois não se chamam

**Faltando a base, o instalador de ferramenta diz o que falta, mostra o comando
pronto na tela e encerra com 1, sem tocar em nada.** Não baixa a base, não a
executa, e não pergunta se pode.

Motivo: a promessa central do projeto é `less` antes de rodar. Um script que
busca e executa outro por conta própria quebra isso — a pessoa leu um arquivo e
dois rodaram. Essa decisão também elimina a necessidade de hash embutido, de
verificação de assinatura e da pergunta de autorização.

Consequência prática: cada instalador é dono da própria conversa, e a regra de
"todas as perguntas antes de qualquer alteração" continua valendo dentro de cada
um, sem coordenação entre eles.

### Estado entre os dois

Não há arquivo de estado. O instalador de ferramenta **redetecta** o Traefik, e
isso é deliberado:

- O código de detecção já existe e foi validado contra três Traefiks diferentes,
  incluindo um configurado por arquivo estático com nomes arbitrários.
- Redetectar é **verificar**. Um arquivo de estado seria acreditado sem prova.
- O Traefik que a nossa base instalou passa a ser tratado igual ao Traefik de
  terceiro. Um caminho só, e a tela diz de onde veio cada valor.

Por isso a confirmação dos valores do Traefik deixou de ser exclusiva do cenário
2: ela acontece sempre.

### Onde o Portainer ficou

Na base, atrás de `--portainer`. Isso resolve de graça o prazo de criação do
administrador: rodando na base, o container sobe e o script termina ali, com a
pessoa na frente do terminal. Instalá-lo no meio de uma instalação de Mautic,
que leva minutos, faria o prazo expirar sempre.

### O menu

`dist/playahead.sh` lista os instaladores e roda o escolhido. Lista numerada,
escolha por número, uma ferramenta por vez.

**O menu contém os instaladores, não os busca.** O `build.sh` embute o
`base.sh` e o `mautic7.sh` dentro dele como heredoc citado — mesmo mecanismo do
template do compose. Escolhido o número, o menu grava o instalador no
diretório atual e passa o terminal para ele com `exec`.

É o que faz o menu conviver com a regra de que um instalador não baixa nem
executa outro. O que se ganha:

- nada é buscado na rede, então um download e um `less` bastam para auditar
  tudo que pode rodar;
- sem colisão de nomes: os instaladores entram como texto, não como código
  concatenado, e cada um mantém o seu `main`, `PA_VERSAO` e `PA_FERRAMENTA`;
- o `$0` do instalador fica certo, porque ele roda de um arquivo com o nome
  real em vez de um temporário — verificado, sai `./base.sh`;
- a pessoa fica com os scripts no disco, para reler e reusar.

O preço é o tamanho: cerca de 7.600 linhas. Como um `less` nisso é pesado, o
cabeçalho impresso na tela diz **em que linha cada instalador começa**, lendo o
próprio arquivo em tempo de execução em vez de confiar num número gravado no
build. E `--extrair` grava os dois em arquivos separados, sem instalar nada,
para quem preferir auditar um por um.

O menu não detecta estado nem mostra "já instalada" na lista. Faria ele
carregar `checks`, `cenario`, `docker` e `traefik` só para desenhar a tela, e
cada instalador já detecta e explica o seu estado quando roda. Fica para quando
a lista virar um painel.

Sem terminal, o menu recusa e manda usar os instaladores direto. Isso também
cobre quem tenta `curl | bash`.

## Requisitos funcionais

Quem decide em qual situação a máquina está é `lib/cenario.sh`, compartilhado
pelos dois instaladores. Não são dois estados, são cinco — e as duas linhas que
abortam só interessam a quem vai subir um proxy, ou seja, à base:

| Docker  | Traefik  | Portas 80/443 | Situação        | Ação                                  |
|---------|----------|---------------|-----------------|---------------------------------------|
| ausente | —        | livres        | **Cenário 1**   | a base instala Docker, Compose e Traefik |
| ausente | —        | ocupadas      | bloqueado       | a base **aborta**: há servidor web no host |
| presente| ausente  | livres        | **Cenário 1.5** | a base pula o Docker e instala o Traefik |
| presente| ausente  | ocupadas      | ambíguo         | a base **aborta**, mostrando quem ocupa |
| presente| rodando  | —             | **Cenário 2**   | base pronta; a ferramenta pode instalar |

Para o instalador de ferramenta não existem cinco estados, existem dois: a base
está pronta, ou falta rodar a base. Nos cenários 1 e 1.5 ele diz o que falta e
encerra sem tocar em nada.

Swarm ativo aborta em qualquer linha (ver seção Swarm).

No cenário 2, nada pode ser assumido. Nomes de entrypoint, de certresolver e de
rede do Traefik são arbitrários e variam por instalação (quem usou outros
instaladores populares tem nomes diferentes de `websecure`, `letsencrypt` e
`traefik_public`). O script precisa inspecionar o container do Traefik em
execução, extrair os valores reais, mostrar o que encontrou e pedir confirmação
antes de aplicar. Se cravar os nomes padrão, o container sobe, o Mautic funciona
e o domínio devolve 404 sem nenhuma mensagem de erro.

## Ordem das etapas

Princípio que organiza os dois: **todas as perguntas acontecem antes de
qualquer alteração na máquina.** Depois que a instalação começa, ela vai até o
fim sem input. Cada instalador é dono da própria conversa.

**base.sh**

0. Parse de flags, `--help` e `--version` (saem sem tocar em nada).
   Cabeçalho MIT/AVISO na tela, pausa curta, segue.
1. Checagens de máquina: bash real, root/sudo, arquitetura, sistema
   operacional, RAM, disco.
2. Classificação do estado. Swarm ativo para aqui. Havendo proxy, mostra o que
   detectou; não havendo, exige as portas 80 e 443 livres.
3. Perguntas: e-mail do ACME, se vai instalar o Traefik; subdomínio do
   Portainer, se pedido.
4. Validação do DNS do Portainer, que **avisa em vez de abortar**.
5. Swap, Docker, Compose, rede do proxy, Traefik.
6. Portainer, se pedido, com o aviso do prazo do primeiro acesso.
7. Bloco final, com os nomes que os instaladores de ferramenta vão detectar.

**mautic7.sh**

0. Parse de flags, `--help` e `--version`. Cabeçalho e pausa.
1. Checagens de máquina, as mesmas: ele também roda sozinho.
2. **A base está pronta?** Faltando, diz o que falta, mostra o comando e
   encerra com 1, sem tocar em nada.
3. Detecção de instalação anterior, **antes** de perguntar qualquer coisa, para
   não fazer a pessoa digitar o domínio à toa.
4. Bloco único de perguntas, incluindo a confirmação dos valores do Traefik.
5. Validação do DNS do domínio do Mautic. Última chance de abortar sem ter
   escrito nada.
6. Mautic, em três tempos (ver Stack), mais idioma, fuso e cache.
7. Verificação externa de roteamento (anti-404).
8. Bloco final.

## Checagens obrigatórias antes de qualquer instalação

Falhar cedo, com mensagem clara em português, é o requisito mais importante do
projeto. Cada falha silenciosa aqui vira comentário de "não funcionou" no vídeo.

- **Sistema operacional: Ubuntu 22.04 e 24.04 no lançamento.** Debian 12 fica
  para uma versão seguinte, depois de testado. Cada SO a mais é uma matriz de
  teste a mais e um tipo novo de comentário no vídeo.

  Refinamento obrigatório: **versão de Ubuntu LTS mais nova que a lista não
  bloqueia.** Avisa que não foi testada e pergunta se continua. Bloquear por
  padrão significa que o script morre sozinho no dia em que o 26.04 sair.
  Versão mais antiga que 22.04, ou distribuição fora da lista, barra.

- Usuário root ou sudo. **O script não se re-executa sozinho com sudo.** Num
  script que acabou de pedir para a pessoa ler antes de rodar, escalar
  privilégio por conta própria passa a impressão errada. Detecta, explica e
  manda rodar de novo com `sudo`.

- RAM mínima 2 GB, 4 GB recomendado. Disco livre mínimo a definir no teste.

- Portas 80 e 443 livres (cenários 1 e 1.5). No cenário 2 essa checagem é
  pulada: o Traefik ocupa as duas legitimamente.

- Arquitetura x86_64.

- **O domínio informado resolve para o IP público desta máquina.**
  Esta é a checagem que mais economiza suporte. Se o DNS aponta para outro
  lugar, o Let's Encrypt falha e a pessoa culpa o script. Mostrar os dois IPs
  na mensagem de erro. Detalhes na seção seguinte.

### Descoberta do IP e a exceção do Cloudflare

O IP público é descoberto **localmente primeiro** (`ip route get`), caindo para
serviço externo só quando a máquina está atrás de NAT. No fallback, dizer na
tela qual serviço está sendo consultado e por quê: a documentação promete que o
script não envia nada, e consultar um terceiro carregando o IP da VPS merece ser
anunciado.

A resolução do domínio usa `getent hosts`, não `dig` — `dnsutils` não vem
instalado no Ubuntu limpo.

**Cloudflare com proxy ativo dá falso positivo e não é caso raro no nosso
público.** Com a nuvenzinha laranja ligada, o domínio resolve para um IP do
Cloudflare, não para o da VPS. O DNS está certo e o script abortaria dizendo que
está errado.

Comportamento exigido:

- Se o IP resolvido não bate com o da máquina, verificar se pertence a faixa
  conhecida de CDN. A lista de faixas fica embutida no script, não é baixada.
- Pertencendo a CDN: **avisar, não bloquear.** O aviso precisa mencionar que o
  modo de SSL no Cloudflare tem de ser Full (strict); em modo Flexible o Mautic
  entra em laço de redirecionamento, que é o próximo chamado de suporte.
- Não pertencendo a nenhuma faixa conhecida: abortar como antes, mostrando os
  dois IPs e citando `--skip-dns-check` na própria mensagem de erro.
- `--skip-dns-check` desliga a checagem inteira, para quem sabe o que está
  fazendo.

Este é o mesmo cenário do Traefik sem certresolver, visto do outro lado: quem
termina TLS no Cloudflare não precisa de Let's Encrypt na VPS. Os dois pontos
têm de ser coerentes entre si.

## Swap

No cenário 1 e 1.5, **se a RAM for menor que 3800 MB e não houver swap
nenhum, criar um swapfile de 2 GB**, anunciando na tela. `--no-swap`
desliga.

O limiar é 3800 MB, não 4096. Uma VPS vendida como "4 GB" reporta 3915 MB
depois do que o kernel reserva — medido na máquina de teste. Comparar com
4096 daria swap a toda máquina de 4 GB, que não precisa. É a mesma correção
que levou o piso de RAM a ser 1900 e não 2048.

Motivo: 2 GB é o piso do README, e MariaDB mais três containers PHP nesse
espaço colocam o `cache:warmup` do Symfony em risco de OOM. OOM não deixa
mensagem clara — o container simplesmente morre. É uma das falhas mais confusas
que existem e resolvê-la na origem custa três linhas.

Criar swap é aditivo, não viola a regra de nada destrutivo. Cuidados:

- Não criar um segundo swapfile se já existe swap ativo, nem se o arquivo já
  estiver lá (idempotência).
- Persistir em `/etc/fstab`, senão some no primeiro reboot.
- Conferir espaço em disco antes.
- Registrar no bloco final que o swap foi criado e onde.

## Interface de linha de comando

O script atende dois públicos com o mesmo código: a pessoa do vídeo, que
responde duas ou três perguntas, e a instalação do serviço pago, que roda sem
ninguém olhando. Isso só fecha com flag para tudo.

Cada instalador tem o seu conjunto. Nenhuma flag é compartilhada por acidente:
o que saiu do `mautic7.sh` saiu porque a responsabilidade mudou de dono.

**base.sh**

| Flag | Efeito |
|---|---|
| `--acme-email=` | e-mail do Let's Encrypt |
| `--portainer` | instala o Portainer também |
| `--portainer-domain=` | subdomínio do Portainer |
| `--skip-dns-check` | pula a validação de DNS |
| `--no-swap` | não cria swapfile |
| `--yes` | não interativo: nenhuma pergunta, falha se faltar dado |
| `--help` | lista as opções |
| `--version` | imprime versão e data de build |

**mautic7.sh**

| Flag | Efeito |
|---|---|
| `--domain=` | domínio do Mautic |
| `--admin-email=` | e-mail do admin do Mautic |
| `--traefik-network=` | força o nome da rede em vez de detectar |
| `--traefik-entrypoint=` | força o nome do entrypoint |
| `--traefik-certresolver=` | força o nome do certresolver |
| `--no-certresolver` | TLS terminado fora; omite o label de certresolver |
| `--idioma=` | idioma do painel; padrão `pt_BR` |
| `--fuso=` | fuso horário da aplicação; padrão `America/Sao_Paulo` |
| `--wizard` | não conclui a instalação, deixa o assistente web |
| `--skip-dns-check` | pula a validação de DNS |
| `--yes` | não interativo: nenhuma pergunta, falha se faltar dado |
| `--help` | lista as opções |
| `--version` | imprime versão e data de build |

### Inventário de perguntas

**base.sh**

| # | Pergunta | Quando | Default | Flag |
|---|---|---|---|---|
| 1 | E-mail para o Let's Encrypt | só se vai instalar o Traefik | — | `--acme-email=` |
| 2 | Subdomínio do Portainer | só com `--portainer` | — | `--portainer-domain=` |
| 3 | Continuar em Ubuntu LTS não testado? | só se o SO for LTS mais nova | sim | — |

**mautic7.sh**

| # | Pergunta | Quando | Default | Flag |
|---|---|---|---|---|
| 1 | Domínio do Mautic | bloco único | obrigatória | `--domain=` |
| 2 | E-mail do admin | bloco único | `admin@dominio` | `--admin-email=` |
| 3 | Confirmar valores do Traefik | bloco único, sempre | aceitar o detectado | `--traefik-*` |
| 4 | Continuar em Ubuntu LTS não testado? | só se o SO for LTS mais nova | sim | — |

Duas mudanças com a separação da base: a pergunta do Portainer saiu do
instalador de ferramenta, porque ele mora na base; e a confirmação do Traefik
passou a acontecer **sempre**, e não só no cenário 2, porque a ferramenta trata
todo Traefik como sendo de outro script.

Nenhuma exige digitar "concordo". Com `--yes` mais as flags, nenhuma aparece.

A pergunta 7 é a única fora do bloco único, e é de confirmação, não de
dado: ela nasce da regra de não bloquear LTS mais nova, e só existe quando
essa regra dispara. Não fere o princípio de perguntar antes de mexer na
máquina, porque a etapa 1 acontece antes de qualquer alteração.

No modo `--yes` ela adota o padrão e segue, em silêncio. É o comportamento
certo para o serviço pago, onde a VPS é escolhida pela agência; para quem
está seguindo o vídeo, a pergunta aparece normalmente.

O admin do Mautic precisa de nome e sobrenome; usar `Admin` / `Play Ahead` sem
perguntar. Não é dado que valha uma pergunta.

## Detecção do Traefik no cenário 2

Identificação: container em execução cuja imagem casa com `traefik`. Havendo
mais de um, perguntar qual. Havendo zero mas alguém segurando o 443, mostrar
quem é e parar.

Extração dos valores, em ordem de precedência. Cada valor guarda de onde veio,
para aparecer na tela na hora da confirmação:

1. `Cmd` / `Args` / `Entrypoint` do `docker inspect` — procurar
   `--entrypoints.<nome>.address=:443` e `--certificatesresolvers.<nome>.acme.*`
2. variáveis de ambiente do container (`TRAEFIK_ENTRYPOINTS_*`,
   `TRAEFIK_CERTIFICATESRESOLVERS_*`) — o Traefik aceita configuração por env
3. labels do próprio container do Traefik
4. **arquivo estático lido de dentro do container** (`traefik.yml`, `.yaml`).
   É o formato que os instaladores populares mais usam, e uma detecção que só
   olha flags de CLI passa direto por ele
5. rede: `NetworkSettings.Networks` menos `bridge`, `host` e `none`. Se
   `--providers.docker.network=` estiver presente, ele tem precedência sobre
   tudo. Sobrando mais de uma candidata, perguntar
6. o que não for encontrado é perguntado, com o default apenas como sugestão

Depois, mostrar tabela com valor e origem de cada item e pedir confirmação.

Casos que a detecção precisa tratar sem inventar valor:

- **Traefik em `network_mode: host`.** O label `traefik.docker.network` deixa de
  fazer sentido. Avisar e tratar à parte.
- **Traefik sem nenhum certresolver.** Típico de quem termina TLS no Cloudflare.
  O label de certresolver tem de ser **omitido**, nunca preenchido com
  `letsencrypt` no chute. É o que `--no-certresolver` força manualmente.

## Conclusão da instalação: via CLI

O script conclui a instalação com `mautic:install`, gerando usuário e senha de
admin, e entrega o painel pronto para login.

Motivo: um instalador que para antes do fim quebra a idempotência e reintroduz
o erro de digitação de credenciais de banco que o próprio script acabou de
resolver. Além disso, o mesmo script roda nas instalações do serviço pago, onde
preencher formulário no navegador a cada cliente não escala.

Uma flag `--wizard` pula o `mautic:install` e deixa o assistente web aparecer,
para quem quiser acompanhar o processo. **É um `if` no final, não um caminho paralelo** — confirmado pelo
teste B14: as variáveis de ambiente configuram só a conexão com o banco, e a
imagem não conclui a instalação sozinha.

Com `--wizard`, o bloco final precisa imprimir também **as credenciais do
banco** — host `mariadb`, usuário `mautic` e a senha gerada. Sem isso a pessoa
não completa o assistente, porque a senha nasceu dentro do script.

Cuidados obrigatórios:

- Senha de admin gerada com `openssl rand`, nunca fixa.
- Senha do admin entregue em `--admin_password`, porque o Mautic 7 não
  oferece alternativa: o comando não lê stdin e não existe
  `mautic:user:create`. Ela não entra no histórico do shell, porque quem
  monta a linha é o script, e não aparece em `docker inspect`, porque não
  é variável de ambiente do container. Aparece num `ps` do host durante os
  segundos do comando, e isso não tem contorno — ver Resultado do teste B14.
- Rodar o instalador com `-d date.timezone=UTC` e `-w /var/www/html`.
  Sem o override, toda instalação brasileira falha na checagem de
  requisitos; sem o `-w`, o console nem é encontrado.
- Detectar instalação já existente e não reinstalar por cima.
- Imprimir URL, e-mail do admin, senha e caminho do `.env` no bloco final.

### Onde as credenciais ficam guardadas

`/opt/playahead/mautic/credenciais.txt`, com `chmod 600`, contendo o admin, a
senha e também as credenciais do banco.

O bloco final aponta o caminho e sugere guardar num gerenciador de senhas.

**Não apagar automaticamente.** O público esquece o terminal aberto e fecha, e
ficar sem acesso é pior que o arquivo local, que está no mesmo servidor onde o
`.env` já vive. A senha do admin não está no `.env` e no banco está com hash: se
o terminal se perder, ela se perde junto.

## Comportamento esperado

- Idempotente, com semântica definida abaixo.
- Senhas geradas com `openssl rand`, nunca fixas no código.
- Esperar o healthcheck responder de verdade antes de declarar sucesso. Nada de
  `sleep 120`. Toda espera tem timeout e mensagem dizendo o que está esperando.
- Mensagens em português, sem jargão desnecessário.
- Passar em `shellcheck` sem warnings, no fonte e no `dist/mautic7.sh` gerado.
- Sem rollback. Falhando no meio, o script **não derruba nada**: imprime o
  estado e os comandos de diagnóstico.

### Idempotência

Rodar de novo não pode destruir banco nem sobrescrever `.env`. Três estados:

| Estado encontrado | Comportamento |
|---|---|
| Nada | Instalação nova |
| Coerente (`.env` + volume + containers) | **Reconcilia e sai com 0.** Reimprime o bloco final e oferece `docker compose up -d` |
| Parcial (volume sem `.env`, ou o contrário) | **Aborta e explica** |

Só o estado parcial aborta. É o caso perigoso: senha nova contra banco antigo
gera erro de autenticação que parece bug do script.

### Verificação anti-404

Depois de subir, o script faz `curl` no domínio, de fora, e espera 200 ou 302.

Devolvendo 404, a mensagem é específica — "o Traefik respondeu, mas não roteou
para o Mautic" — lista os três valores usados, diz que provavelmente estão
errados e mostra como corrigir editando o `.env` e rodando `up -d`. Não derruba
nada.

Sem este passo o modo de falha descrito nos Requisitos funcionais continua
silencioso, que é exatamente o que o projeto tenta evitar.

### Nada destrutivo

Este é um requisito de proteção, não de conveniência. Um script que não destrói
nada raramente vira problema, jurídico ou de reputação.

- Nunca sobrescrever `.env` existente.
- Nunca executar `docker system prune` ou equivalente.
- Nunca alterar configuração de Traefik que já está rodando sem avisar e pedir
  confirmação explícita.
- Diante de instalação anterior parcial, parar e explicar, em vez de seguir.
- Operações aditivas (criar swap, criar rede, criar diretório) são permitidas,
  desde que anunciadas e idempotentes.

## Licença e aviso legal

Licença MIT. Arquivo `LICENSE` na raiz do repositório. Sem licença explícita,
ninguém tem permissão formal de redistribuir ou modificar o script, e ele vai
circular.

O artefato publicado traz este bloco como cabeçalho e o imprime na tela no início da
execução, com uma pausa curta:

    # ============================================================
    # PLAY AHEAD INSTALLER
    # https://playahead.com.br
    # Fabio Roger de Oliveira ME | CNPJ 31.176.090/0001-08
    #
    # Licença MIT. Consulte o arquivo LICENSE.
    #
    # AVISO
    # Este script altera a configuração do servidor onde é executado:
    # instala pacotes, cria containers, volumes e regras de rede.
    # Execute apenas em servidor dedicado a esta finalidade e do qual
    # você tenha cópia de segurança.
    #
    # O software é fornecido "como está", sem garantia de qualquer
    # espécie. A Play Ahead não se responsabiliza por perda de dados,
    # indisponibilidade ou danos decorrentes do uso.
    #
    # Leia o código antes de executar.
    # ============================================================

Não pedir confirmação digitada do tipo "digite concordo". Isso trava instalação
automatizada e atrapalha a gravação do vídeo.

Observação: cláusula de exclusão total de responsabilidade tem eficácia limitada
no Brasil, porque o Código de Defesa do Consumidor considera abusivas as
cláusulas que exonerem a responsabilidade do fornecedor. O aviso alinha
expectativa e reduz risco, mas quem protege de verdade é a regra "nada
destrutivo" acima.

## Dados pessoais e LGPD

**Sem telemetria.** O script não envia nenhuma informação automaticamente. Não
registra instalações, não contabiliza execuções, não coleta IP. Qualquer envio
para servidor da Play Ahead precisa ter sido pedido e aceito pela pessoa naquela
execução.

O e-mail pedido para o Let's Encrypt vai para a Let's Encrypt, não para a Play
Ahead, e a pergunta precisa deixar isso explícito na tela.

**Captação de contato: por link, não por formulário no terminal.**

A decisão atual é não coletar nome nem e-mail dentro do script. No bloco final,
imprimir um convite com URL:

    Quer receber avisos de novas versões, correções e conteúdos da
    Play Ahead sobre automação de marketing?
    https://playahead.com.br/avisos

Motivo: nenhuma linha do código toca dado pessoal, e um script bash que envia
e-mail para um servidor gera desconfiança pública mesmo quando é legítimo. A
pessoa acabou de concluir a instalação, que é um bom momento de conversão.

**A base é usada também para marketing**, incluindo divulgação do treinamento
Impulse e dos serviços da agência. Isso precisa estar declarado no momento da
coleta. A LGPD proíbe tratar o dado para finalidade diferente da informada, então
texto que fale apenas em "avisos de versão" inviabiliza o uso comercial da lista.

Como a inscrição é totalmente voluntária e nada na instalação depende dela, o
consentimento é livre e as duas finalidades podem ficar num único opt-in, desde
que o texto seja explícito. Caixas separadas seriam necessárias apenas se algum
serviço fosse condicionado à aceitação.

### Página de inscrição (playahead.com.br/avisos)

Requisitos da página:

- Texto do consentimento explicitando as duas finalidades. Modelo:
  "Quero receber avisos de novas versões e correções do instalador, além de
  conteúdos, novidades e ofertas da Play Ahead sobre automação de marketing.
  Posso cancelar a qualquer momento."
- Identificação do controlador: Fabio Roger de Oliveira ME,
  CNPJ 31.176.090/0001-08.
- Link para a política de privacidade e canal de contato para pedidos de acesso,
  correção e exclusão de dados.
- Double opt-in, tanto por prova de consentimento quanto por higiene de lista.
- Registro do consentimento: data, hora, IP, origem (instalador) e a versão exata
  do texto aceito.
- Link de descadastro em todo e-mail enviado.
- Segmento próprio no Mautic identificando a origem, para medir conversão do
  instalador e permitir tratamento separado se a finalidade mudar.

**Se no futuro a coleta passar a ser feita dentro do script**, valem as mesmas
regras, mais estas:

- Opcional de verdade. Enter pula, e a instalação segue idêntica.
- Nenhuma opção pré-marcada como aceita.
- Exibir controlador, finalidades e forma de cancelamento antes de perguntar.
- Envio por HTTPS.

## Stack

Serviços: MariaDB, mautic_web, mautic_cron, mautic_worker.

**Local de instalação: `/opt/playahead/mautic/`**, com o compose gravado como
`docker-compose.yml` para que `docker compose up -d` funcione sem `-f`. O
namespace `/opt/playahead/` já abre espaço para os próximos instaladores.

    /opt/playahead/mautic/docker-compose.yml
    /opt/playahead/mautic/.env
    /opt/playahead/mautic/credenciais.txt      chmod 600

O template `templates/docker-compose-mautic7-playahead.yml` expõe
`TRAEFIK_NETWORK`, `TRAEFIK_ENTRYPOINT` e `TRAEFIK_CERTRESOLVER` como variáveis
com default, exatamente para atender o cenário 2. O script gera o `.env` que
alimenta essas variáveis, com `umask 077`.

Ajustes do template, aplicados e validados em VPS:

- **Tags de imagem em variável.** `${MAUTIC_IMAGE:-mautic/mautic:7-apache}` e
  `${MARIADB_IMAGE:-mariadb:10.11}`, conforme a regra de manter a versão fácil
  de trocar.
- **Healthcheck no `mautic_web`**, por `curl` no Apache de dentro do container.
  `start_period` de 120s porque o primeiro boot faz cache warmup. Medido: fica
  `healthy` em 45s. Sem ele não há como "esperar de verdade".
- **Cabeçalho reescrito.** O anterior mandava completar o assistente de
  instalação, contradizendo o que o script faz. O novo diz que o arquivo é
  gerado pelo instalador, e traz o passo a passo manual para quem usar o
  template sozinho — incluindo o `-d date.timezone=UTC`, sem o qual a
  instalação por CLI reprova.
- **Volume para `docroot/translations`**, nos três serviços do Mautic. Motivo
  na seção abaixo.

### Idiomas: por que translations precisa de volume

O pacote de idioma pt_BR é instalado em tempo de execução e fica em
`docroot/translations/`. Esse caminho não estava em volume nenhum, então
**sumia toda vez que o container fosse recriado** — o que acontece em qualquer
`docker compose up -d` depois de mudar o compose, ou ao atualizar a imagem.

Confirmado na VPS de teste: com `pt_BR` instalado, um
`docker compose up -d --force-recreate mautic_web` deixou o diretório com
apenas o `.htaccess` da imagem. A interface volta para inglês sozinha e nada
no log explica por quê.

Não há caminho por CLI: o console do Mautic 7 só tem `mautic:transifex:pull` e
`push`, que são ferramentas de tradutor e exigem credencial do Transifex. Não
existe `mautic:language:install`. Instalar o idioma é ação de interface.

**Volume nomeado, e não bind mount.** A imagem traz um `.htaccess` com
`deny from all` nesse diretório, protegendo os arquivos de acesso pela web.
Volume nomeado vazio recebe uma cópia do conteúdo da imagem na primeira
subida, e o `.htaccess` vai junto — verificado. Bind mount não copia nada da
imagem: o diretório nasceria vazio, sem a proteção.

Risco conhecido e aceito: volume nomeado sombreia atualizações futuras da
imagem naquele caminho. Aqui isso quase não custa, porque a imagem só traz o
`.htaccess` de 13 bytes; os idiomas sempre vêm de download em tempo de
execução.

**Nota de atualização.** Quem já tem uma instalação anterior e passa a usar o
compose novo perde o idioma uma vez. O volume nasce com o conteúdo da
*imagem*, não com o da camada de escrita do container antigo. Basta reinstalar
o idioma pela interface; a partir daí ele persiste.

O volume vai nos três serviços, e não só no `mautic_web`, pelo mesmo motivo de
`config`, `media` e `logs` já irem: o `mautic_cron` dispara campanhas e o
`mautic_worker` consome a fila de e-mail, e os dois renderizam conteúdo. Idioma
presente só na web produziria e-mail em inglês sem nenhum aviso.

### Ordem de subida

Em três tempos, não um `up -d` só:

1. `up -d mariadb`, esperar ficar `healthy`
2. `up -d mautic_web`, esperar o Apache responder dentro do container, e então
   rodar o `mautic:install` (ou pular, com `--wizard`)
3. `up -d` completo, subindo cron e worker

Motivo: com `depends_on: service_started`, cron e worker sobem antes de o banco
estar instalado e ficam em laço de erro, queimando CPU e poluindo o log
justamente na hora em que a pessoa está olhando a tela.

## Armadilhas já confirmadas na documentação oficial

Estas foram verificadas. Não mudar sem checar a fonte de novo.

- **Traefik exige crases na regra.** O valor precisa vir entre crases ou aspas
  duplas escapadas. Aspas simples não são aceitas. Sem crase a regra não compila
  e o roteador nem é criado.
- **Filas.** Sem `MAUTIC_MESSENGER_DSN_EMAIL` e `MAUTIC_MESSENGER_DSN_HIT` com
  valor `doctrine://default`, os workers sobem e não consomem nada, e o envio de
  e-mail acontece de forma síncrona. O valor não pode ter aspas no compose, senão
  as aspas entram na variável e a aplicação erra com "No transport supports the
  given Messenger DSN".
- **Trusted proxies.** `MAUTIC_TRUSTED_PROXIES` é lido como JSON pelo Symfony.
  Precisa ser um array JSON válido, por exemplo `["0.0.0.0/0"]`. String solta
  quebra a aplicação na inicialização.
- **`PHP_INI_VALUE_POST_MAX_FILESIZE` é o nome correto.** Está assim no README
  oficial da imagem, com default 512M, mesmo parecendo errado em relação à
  diretiva `post_max_size` do PHP. Não "corrigir".
- **Versões mínimas do Mautic 7:** PHP 8.2, MySQL 8.4.0 ou MariaDB 10.11.0. A
  stack usa `mariadb:10.11`, que é o piso e é LTS.
- **A tag `mautic/mautic:7-apache` hoje entrega Mautic 7.1.x**, não 7.0. Manter a
  versão numa variável no topo do script, fácil de trocar.
- Usar a variante `apache`. A documentação oficial desaconselha a `fpm`.
- **`America/Sao_Paulo` reprova na checagem de requisitos do `mautic:install`.**
  A checagem do Symfony monta a lista de fusos aceitos a partir de
  `DateTimeZone::listAbbreviations()`, que tem 376 entradas, e não de
  `timezone_identifiers_list()`, que tem 419. Nenhum fuso brasileiro está nas
  376, porque o fim do horário de verão em 2019 tirou BRT e BRST do banco de
  fusos. Rodar o instalador com `-d date.timezone=UTC`. O assistente web não é
  afetado. Verificado na imagem, não na documentação.

## Estrutura pretendida

    build.sh                gera os artefatos de dist/ a partir de lib/
    dist/base.sh            artefato publicado: Docker, Traefik, Portainer
    dist/mautic7.sh         artefato publicado: Mautic 7
    dist/playahead.sh       artefato publicado: menu, com os dois embutidos
    LICENSE                 MIT
    templates/              arquivos docker-compose

    lib/ui.sh               cores, prompts, mensagens        compartilhado
    lib/checks.sh           pré-checagens e validadores      compartilhado
    lib/cenario.sh          classificação do estado          compartilhado
    lib/docker.sh           detecção do Docker               compartilhado
    lib/traefik.sh          detecção do Traefik              compartilhado

    lib/portas.sh           portas em escuta                 base
    lib/sistema.sh          swap                             base
    lib/docker_instalar.sh  instalação do Docker             base
    lib/traefik_instalar.sh instalação do Traefik            base
    lib/portainer.sh        instalação do Portainer          base
    lib/base_main.sh        orquestrador da base             base

    lib/mautic.sh           .env, stack e regionalização     mautic7
    lib/mautic_main.sh      orquestrador do Mautic           mautic7

    lib/menu_main.sh        orquestrador do menu             playahead

Só o compose do Mautic é template em arquivo. Os do Traefik e do Portainer
são gerados em código, por `traefik_gerar_compose` e
`portainer_gerar_compose`: os dois dependem de valores descobertos em
execução (rede, entrypoint, certresolver), e um template com marcador para
cada um deles seria mais difícil de ler que o heredoc que o gera.

## Decisões tomadas

**Traefik: versão fixa da linha v3, nunca `latest`.** Fixar a minor exata numa
variável no topo do script (por exemplo `TRAEFIK_VERSION="v3.x"`), conferindo a
release estável atual no momento da implementação. O instalador trabalha com
Docker Compose puro, não Swarm, então a incompatibilidade entre Traefik v3 e
Docker Engine 29.x observada em Swarm não se aplica aqui. Ainda assim, validar em
VPS descartável antes de publicar. A sintaxe dos labels no compose já é
compatível com v2 e v3.

**Portainer: opcional, e depois do Mautic.** Não entra no fluxo principal. Fica
atrás da flag `--portainer` e de uma pergunta ao final da execução.

A flag `--portainer` antecipa apenas a **pergunta do subdomínio**, que passa para
o bloco único de perguntas. A **instalação** continua sendo a última etapa, em
qualquer caso.

A ordem importa mais que a escolha. O Portainer exige subdomínio próprio e
certificado próprio, ou seja, mais um apontamento de DNS que pode falhar. Se ele
rodasse antes, uma falha de DNS dele derrubaria a instalação inteira. Instalando
depois que o Mautic já está de pé e funcionando, uma falha ali é um aviso, não um
desastre, e a pessoa termina com o Mautic funcionando de qualquer jeito.

Para o vídeo, isso também abre um gancho natural: o Mautic sobe, funciona, e o
Portainer vira conteúdo do próximo vídeo em vez de mais três minutos de DNS no
meio deste.

## Swarm

O instalador assume Docker Compose puro. Se detectar Swarm ativo na máquina,
avisar e parar, em vez de tentar se adaptar. Suportar os dois modos dobra a
superfície de bug: `depends_on` com `condition: service_healthy` é ignorado no
Swarm, e rede overlay só aceita container externo se tiver sido criada como
`attachable`.

## Fora de escopo

O script não configura SMTP, Amazon SES, SPF, DKIM, DMARC nem aquecimento de
domínio. Isso é deliberado: entregabilidade é o serviço que a Play Ahead vende e
o conteúdo do treinamento Impulse. O script entrega a infraestrutura, não a
operação de e-mail.

## Ambiente de teste

Testar sempre em VPS descartável, nunca na máquina de produção. O ciclo é
destruir e recriar a VPS a cada teste, porque um instalador precisa ser validado
sempre a partir do estado zero.

## Comandos validados em VPS

Validados em 2026-09-01, numa DigitalOcean Ubuntu 24.04.4 LTS, x86_64,
3915 MB de RAM, sem swap, Docker ausente e portas 80/443 livres —
cenário 1 puro. São a base de `lib/docker.sh` e `lib/traefik.sh`.

### Inventário da imagem virgem

Levantado **antes** de qualquer `apt`, senão uma dependência instalada
no caminho contamina a resposta:

| Ferramenta | Estado |
|---|---|
| `ss` | presente (`/usr/bin/ss`) |
| `curl` | presente |
| `netstat` | **ausente** |
| `dig` | presente nesta imagem |
| `getent`, `openssl`, `ip`, `awk`, `df`, `free` | presentes |
| `/proc/net/tcp` | legível |

O `netstat` ausente confirma que ele não serve como primeiro fallback,
e o `/proc/net/tcp` legível confirma que a cadeia de `checks.sh` nunca
se esgota de verdade.

O `dig` estar presente **não** invalida a decisão de usar `getent`:
esta é uma imagem da DigitalOcean, não Ubuntu puro, e o `dnsutils` não
é garantido em Hetzner ou Contabo.

### Docker

Método oficial de repositório, não o script de conveniência do
`get.docker.com`: o repositório é auditável, recebe atualização por
`apt upgrade` junto com o resto do sistema e não pede que a pessoa
execute mais um script remoto logo depois de o instalador ter pedido
para ela ler scripts antes de rodar.

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get install -y -qq ca-certificates curl

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) \
    signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin

Resultado: Docker 29.7.2, Compose v5.5.0, serviço `enabled` e `active`,
Swarm `inactive`. O `docker-ce` já cria e habilita o serviço; não é
preciso `systemctl enable --now`.

**Docker Engine 29.x confirmado em Compose puro.** A incompatibilidade
com Traefik v3 que o projeto registrou vale para Swarm e não apareceu
aqui, como esperado.

### Traefik

Versão fixa `v3.7.12`, estável da linha v3 em 2026-09-01, conferida na
API do Docker Hub em vez de assumida. Nunca `latest`.

    docker network create traefik_public

Compose em `/opt/playahead/traefik/docker-compose.yml`:

    services:
      traefik:
        image: traefik:v3.7.12
        restart: unless-stopped
        command:
          - --providers.docker=true
          - --providers.docker.exposedByDefault=false
          - --entrypoints.web.address=:80
          - --entrypoints.web.http.redirections.entrypoint.to=websecure
          - --entrypoints.web.http.redirections.entrypoint.scheme=https
          - --entrypoints.websecure.address=:443
          - --certificatesresolvers.letsencrypt.acme.email=${ACME_EMAIL}
          - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json
          - --certificatesresolvers.letsencrypt.acme.httpchallenge=true
          - --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web
        ports:
          - "80:80"
          - "443:443"
        volumes:
          - /var/run/docker.sock:/var/run/docker.sock:ro
          - traefik_letsencrypt:/letsencrypt
        networks:
          - traefik_public

    volumes:
      traefik_letsencrypt:
        name: playahead_traefik_letsencrypt

    networks:
      traefik_public:
        external: true
        name: traefik_public

Decisões que o `lib/traefik.sh` precisa preservar:

- `exposedByDefault=false`. Sem isso todo container da máquina vira
  roteador por acidente. O nosso compose já traz `traefik.enable=true`.
- Redirecionamento 80→443 no entrypoint, não por middleware. Um
  middleware precisaria ser referenciado por cada roteador; no
  entrypoint vale para tudo e o `.env` do Mautic não precisa saber.
- `httpchallenge`, não TLS-ALPN. O desafio HTTP é o que funciona
  quando o DNS acabou de ser apontado e ainda não há certificado.
- Socket montado como `:ro`. O Traefik só precisa ler.
- O volume do ACME é nomeado com prefixo `playahead_`, para caber no
  mesmo namespace do resto e não colidir com instalação alheia.

## Resultado do teste B14

Executado em 2026-09-01 na VPS descartável descrita em "Comandos
validados em VPS". Mautic **7.1.2**, entregue pela tag `7-apache`,
confirmando a nota de que a tag não entrega 7.0.

### A imagem NÃO conclui a instalação sozinha

Resposta da pendência que bloqueava a etapa 8. Três evidências
independentes, colhidas com `mariadb` saudável e `mautic_web` de pé,
sem nenhum `mautic:install` ter rodado:

1. `config/local.php` **existe**, mas vem de dentro da imagem (data do
   build) e contém apenas parâmetros de banco, todos como chamadas
   `getenv()`. Não há `site_url`.
2. O banco tem **zero tabelas**.
3. O Apache responde `302` para `/index.php/installer`.

Depois do `mautic:install`, os mesmos três pontos viram: `site_url`
gravado no `local.php`, 124 tabelas e `302` para `/s/dashboard`.

**Consequência de desenho: `--wizard` continua sendo um `if` no final,
não um caminho paralelo.** Não é preciso subir a stack com um
subconjunto das variáveis removido, porque as variáveis de ambiente
configuram a conexão com o banco e nada mais. O desenho do CLAUDE.md
sobrevive ao teste sem alteração.

### Assinatura real do mautic:install

    mautic:install [options] [--] <site_url> [<step>]

`step` é o índice de início: 0 requisitos, 1 banco, 2 admin, 3
configuração, 4 final. Cada passo bem-sucedido dispara o seguinte.
Poder retomar de um passo específico é útil: numa falha no meio, dá
para continuar sem refazer o schema.

Opções que interessam: `--force`, `--admin_firstname`,
`--admin_lastname`, `--admin_username`, `--admin_email`,
`--admin_password`, mais os `--db_*`, que podem ser omitidos porque o
`local.php` da imagem já os resolve por `getenv()`.

### America/Sao_Paulo quebra o instalador via CLI

O achado mais caro do teste, e o menos óbvio.

Com `PHP_INI_VALUE_DATE_TIMEZONE: America/Sao_Paulo`, que é o que o
template traz, o `mautic:install` morre no passo 0:

    Missing requirements:
      - [0] Your default timezone is not supported by PHP.
    Install canceled

O PHP aceita o timezone sem reclamar: `ini_get`, `date_default_timezone_get`
e `timezone_identifiers_list()` concordam que `America/Sao_Paulo` é
válido. A checagem de requisitos do Symfony, porém, monta a lista de
timezones aceitos a partir de `DateTimeZone::listAbbreviations()`, que
tem 376 entradas contra as 419 de `timezone_identifiers_list()`.

**Nenhum timezone brasileiro está nas 376.** Verificados como ausentes:
`America/Sao_Paulo`, `America/Fortaleza`, `America/Bahia` e
`America/Recife`. `UTC`, `America/New_York` e `Europe/Lisbon` estão
presentes. A causa é o fim do horário de verão brasileiro em 2019, que
tirou BRT e BRST do banco de dados de fusos.

Contorno validado, e é o que o `lib/mautic.sh` precisa fazer:

    php -d date.timezone=UTC bin/console mautic:install ...

O override vale só para o processo do instalador. O timezone da
aplicação continua `America/Sao_Paulo`, que é o que importa para os
contatos e para os relatórios.

**O assistente web não é afetado.** Com o mesmo timezone, a página do
instalador responde "Ready to Install". A checagem existe nos dois
caminhos, mas só o CLI trata a falha como fatal. Isso significa que um
usuário de `--wizard` nunca veria este problema, e que sem o override o
caminho padrão do script falharia em 100% das instalações brasileiras.

### A senha do admin não pode ir por stdin

O requisito registrado neste documento — "entregar por stdin, nunca em
`argv`" — **não é atendível** com o Mautic 7.

Testado: omitir `--admin_password` e alimentar a senha pelo stdin faz o
comando chegar ao passo 2 e abortar com `[password] A value is
required`. O comando não pergunta nada e não lê stdin. Não existe
`mautic:user:create` nem equivalente: `bin/console list mautic` não
tem nenhum comando de usuário.

Sobra `--admin_password` em `argv`. Mitigações possíveis, a decidir:

- A exposição dura os poucos segundos do comando, dentro de um
  container, numa VPS de dono único que acabou de ser provisionada.
- Não entra no histórico do shell, porque quem monta a linha é o
  script e não a pessoa.
- `docker inspect` não mostra, porque não é variável de ambiente do
  container.

O que **não** dá para prometer é que a senha não apareça num `ps` do
host durante a execução. O documento precisa dizer isso em vez de
exigir o impossível.

### Limites de PHP: aplicam

Confirmado que a imagem substitui as variáveis dentro do `php.ini`:

    date.timezone="${PHP_INI_VALUE_DATE_TIMEZONE}"
    upload_max_filesize="${PHP_INI_VALUE_UPLOAD_MAX_FILESIZE}"
    post_max_size="${PHP_INI_VALUE_POST_MAX_FILESIZE}"
    memory_limit="${PHP_INI_VALUE_MEMORY_LIMIT}"
    max_execution_time="${PHP_INI_VALUE_MAX_EXECUTION_TIME}"

Por ser o `php.ini`, vale para CLI e Apache igualmente. Medido no CLI:
`memory_limit` 1024M, `upload_max_filesize` 512M, `post_max_size` 512M,
`date.timezone` America/Sao_Paulo. O `max_execution_time` aparece como
0 no CLI, que é o normal — o valor 300 vale para o SAPI web.

**`PHP_INI_VALUE_POST_MAX_FILESIZE` confirmado na prática**: alimenta
`post_max_size`. A armadilha registrada neste documento está certa e
segue valendo.

### Filas e workers: funcionam

Dentro do `mautic_worker`, seis processos, exatamente o que o compose
pede:

    php bin/console messenger:consume email    (x2)
    php bin/console messenger:consume hit      (x2)
    php bin/console messenger:consume failed   (x2)

A tabela `messenger_messages` existe. O `doctrine://default` sem aspas
funciona como documentado.

O `mautic_cron` tem espera própria por banco no entrypoint — o log
mostra "MySQL is not ready yet, waiting..." seguido de "MySQL is alive
and well". Isso reduz, mas não elimina, o motivo da subida em três
tempos: a espera dele é pelo banco responder, não pelo Mautic estar
instalado.

### Caminhos dentro do container

O diretório de trabalho é `/var/www/html/docroot`, mas o console está
em `/var/www/html/bin/console`. Um `docker compose exec ... php
bin/console` falha com "Could not open input file". Todo comando
precisa de `-w /var/www/html`.

O Apache barra `.php` arbitrário no docroot com 403, o que é postura
correta da imagem e impede o truque de jogar um arquivo de diagnóstico
lá dentro.

### Números medidos

| Medida | Valor |
|---|---|
| Disco consumido pela instalação inteira | 4389 MB |
| Imagens Docker | 3844 MB |
| Volumes | 255 MB |
| RAM com a stack completa, ociosa | 1152 MB |
| MariaDB até `healthy` | 6 s |
| Tabelas criadas | 124 |

O piso de 10 GB em `PA_DISCO_MINIMO_MB` está validado: sobra folga
sobre os 4,4 GB de instalação limpa. O de RAM também: 1152 MB ociosos
significam que uma máquina de 2 GB funciona, mas sem margem — o que
sustenta a decisão do swapfile.

## Resultado do teste do cenário 1

Executado em 2026-09-12 numa DigitalOcean de 2 GB, Ubuntu 24.04. Passou de
ponta a ponta: swap, Docker, Traefik, Mautic com SSL, workers e verificação de
roteamento. Quatro problemas apareceram, e três viraram código.

### var/cache e o console rodado como root

**A armadilha mais grave encontrada até agora**, porque limpar cache é a
primeira coisa que se tenta quando algo dá errado.

`docker compose exec` entra como **root** por padrão. O Apache roda como
`www-data`, e `var/cache` **não está em volume**: vive na camada de escrita do
container, de dono `www-data`. Qualquer console rodado como root deixa arquivo
de root ali, e a partir daí o Apache não consegue mais escrever — o Mautic
responde 500.

Medido: um `cache:clear` como root deixou **30.737 arquivos de root** em
`var/cache` e derrubou o site. Os diretórios temporários do Symfony (`.!!AgY`,
`.!!ENs`) também ficam de root, e depois bloqueiam até o `cache:clear` correto,
com "Permission denied" que não explica a causa.

**Volume para `var/cache` foi considerado e rejeitado.** Cache é descartável e
específico da versão: um volume nomeado o preservaria através de atualização de
imagem, que é exatamente quando ele precisa morrer. Seria o problema do volume
de `translations` de novo, mas pior — lá o sombreamento custa idioma velho,
aqui custaria aplicação quebrada.

A correção é de dono, não de volume:

- `mautic_console` centraliza todo comando de console e sempre passa
  `-u www-data`. Nenhum caminho do script roda console como root.
- `mautic_corrigir_dono` devolve `var/` para `www-data`, como root, e roda
  antes de cada `cache:clear` — cobre cache já sujado numa execução anterior.
- O comando correto e a recuperação ficam no `credenciais.txt` e no README.
  Não dá para depender de a pessoa achar a documentação.

Recuperação validada, para quem já caiu no 500:

    docker compose exec mautic_web chown -R www-data:www-data /var/www/html/var
    docker compose exec -u www-data mautic_web php bin/console cache:clear

Reparar o dono é melhor que apagar: o cache se refaz sozinho e nada mais em
`var/` morre por causa disso.

### Idioma: a instalação nasce em pt_BR

O diagnóstico do teste foi preciso: o idioma estava salvo corretamente em
`config/local.php`, e faltava **limpar o cache**. O Mautic guarda a
configuração compilada, então gravar idioma sem limpar não muda nada na tela.

Isso derrubou a nota anterior de que instalar idioma "é ação de interface". Há
caminho por CLI, e ele não usa o console do Mautic:

- O pacote vem de `https://language-packs.mautic.com/<codigo>.zip`. As URLs
  saíram do `app/bundles/CoreBundle/Config/config.php` do próprio Mautic, nas
  chaves `translations_list_url` e `translations_fetch_url`.
- `unzip` **não existe** no Ubuntu limpo, mas a imagem tem PHP com
  `ZipArchive`. Download e extração acontecem dentro do container e como
  `www-data`, o que já deixa o dono certo sem `chown` depois.
- O zip oficial já traz o diretório do idioma na raiz, então extrair em
  `docroot/translations/` basta. Medido: 169 itens, dono `www-data`.

`--idioma` aceita qualquer código do manifesto oficial, e o padrão é `pt_BR`.
Código inexistente **avisa e segue em inglês** em vez de abortar: idioma não
vale derrubar uma instalação que deu certo no resto.

### Fuso: corrigido depois da instalação

O contorno do bug do `America/Sao_Paulo` tem um efeito colateral que o teste
expôs: o instalador roda com `-d date.timezone=UTC` e o Mautic guarda esse UTC
como fuso padrão da aplicação. Horário de campanha e relatório sairiam em UTC.

`mautic_gravar_config` corrige as duas chaves em `config/local.php` depois da
instalação, por substituição no texto. Não por `include` mais `var_export`: o
`local.php` guarda a senha do banco em texto puro e outras chaves que não têm
por que passar por um round-trip. Chave ausente é inserida antes do fecho do
array.

Validado invertendo os valores à mão e rodando a função: voltou para `pt_BR` e
`America/Sao_Paulo`, o `php -l` continua limpo, e o painel abriu com "Usuário",
"Senha" e "Esqueceu" na tela de login.

Com `--wizard` o pacote de idioma entra mas a configuração não: quem completa
o assistente reescreve o `local.php` no fim, e gravar antes seria trabalho
jogado fora. Com o pacote no lugar, o idioma já aparece como opção no próprio
assistente.

### Portainer: os labels estavam certos

A hipótese inicial era que o `lib/portainer.sh`, único módulo sem validação em
VPS, gerava labels errados. **A hipótese estava errada**, e vale registrar por
quê, para não voltar a investigar o lugar errado:

- Os labels do Portainer são **idênticos em estrutura** aos do Mautic, que
  roteou certo.
- O certificado Let's Encrypt **foi emitido** para o subdomínio.
- O log do Traefik não tem **nenhum** erro nem menção ao Portainer.
- A resposta externa é **307, igual à interna** na porta 9000, com
  `location: /timeout.html`. Ou seja: o Traefik roteou, e quem responde 307 é
  o próprio Portainer.

A causa real é o que já estava previsto em `portainer_aviso_primeira_visita`:
o Portainer encerra a criação do administrador poucos minutos depois de subir
e passa a servir a própria página de timeout. A versão 2.45 agrega um **token
de setup**, impresso só no log do container.

O que fazer com isso é decisão de produto, não correção de bug — está em
Pendências.

## Pendências

**Cenário 1 validado de ponta a ponta** em 2026-09-12. A tag `mautic7-v0.1.0`
fica para depois de as correções deste teste serem revalidadas.

**Decisão de produto em aberto: o Portainer continua neste instalador?**

Os labels estão certos e o módulo funciona — ver Resultado do teste do cenário
1. O problema não é técnico, é de encaixe:

- O primeiro acesso do Portainer é deliberadamente hostil a instalação
  desatendida. A janela de poucos minutos e o token de setup existem para
  impedir que um terceiro crie o administrador. Automatizar em volta disso
  significa desligar a postura de segurança dele dentro de um script que
  promete não fazer nada surpreendente.
- É a única peça que não consegue honrar a promessa central do projeto,
  "entrega o painel pronto para login".
- É também a única cujo sucesso depende de a pessoa agir em minutos, e a única
  que exige um segundo apontamento de DNS. Os dois maiores geradores de
  comentário "não funcionou" do projeto.

Alternativa: `dist/portainer.sh` como instalador próprio, no mesmo
repositório, com README próprio explicando o prazo do primeiro acesso. O
CLAUDE.md já previa que "o Portainer vira conteúdo do próximo vídeo".

Custo de remover daqui: `lib/portainer.sh` sai, as flags `--portainer` e
`--portainer-domain` saem, e o inventário de perguntas cai de sete para cinco
— o que simplifica o fluxo que o vídeo tem de explicar.

**Ainda sem decisão:**

- Log da execução para suporte (caminho, rotação e mascaramento de segredos).
- `.env.example`, que o `.gitignore` já prevê com `!.env.example` mas não
  existe.
