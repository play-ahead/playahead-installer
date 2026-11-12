# Play Ahead Installer

Instaladores em Docker para VPS, mantidos pela
[Play Ahead](https://playahead.com.br).

São dois tipos de instalador, e a ordem importa:

**A base**, que roda uma vez por VPS e entrega o que todas as ferramentas
compartilham: swap, Docker, Docker Compose, a rede do proxy, o Traefik com
certificado SSL automático e o Portainer.

**Os instaladores de ferramenta**, que reaproveitam essa base em vez de
recriá-la. Hoje só o do Mautic 7 existe; Chatwoot, Typebot e Evolution API
entram depois, cada um com o seu próprio arquivo em `dist/`.

O instalador do Mautic 7 sobe a stack completa e pronta para produção: Mautic 7
(web, cron e workers), MariaDB, e o painel já em português do Brasil.

## Requisitos

- VPS com Ubuntu 22.04 ou 24.04, arquitetura x86_64
- Acesso root ou sudo
- 2 GB de RAM no mínimo (4 GB recomendado)
- Um domínio ou subdomínio apontando para o IP da VPS
- A base instalada, no caso dos instaladores de ferramenta

Versões de Ubuntu LTS mais novas que essas não são bloqueadas: o script avisa
que não foram testadas e pergunta se você quer continuar. Debian 12 entra numa
versão futura, depois de testado.

O apontamento de DNS precisa estar feito **antes** de rodar o script. Sem isso o
certificado SSL não é emitido.

## Como usar

O caminho mais curto é o menu, que lista as ferramentas e roda a que você
escolher. Hoje são duas, a base e o Mautic 7, e outras entram na mesma lista
conforme forem publicadas:

    curl -sL https://get.playahead.com.br -o playahead.sh
    less playahead.sh
    sudo bash playahead.sh

**O menu contém os instaladores, não os baixa.** Nada é buscado na hora, então
o que você leu é o que pode rodar. Como o arquivo é grande, ele imprime na tela
em que linha cada instalador começa, e `--extrair` grava cada um num arquivo
separado se você preferir ler um por um.

Escolhido o número, o menu grava o instalador no diretório atual e roda. Quando
ele termina, a lista volta, para você escolher a próxima: instalou a base,
escolha o Mautic em seguida. O `0` sai. Um Ctrl-C no meio de um instalador
interrompe só ele, e o menu volta.

A lista mostra `instalado` ao lado do que já existe na VPS. É só uma indicação:
quem confere de verdade a situação da máquina é cada instalador, quando roda.

### Ou direto, por instalador

Cada um tem URL própria. Primeiro a base, uma vez por VPS:

    curl -sL https://get.playahead.com.br/base -o base.sh
    less base.sh
    sudo bash base.sh

Depois o Mautic:

    curl -sL https://get.playahead.com.br/mautic7 -o mautic7.sh
    less mautic7.sh
    sudo bash mautic7.sh

O passo do `less` não é enfeite. Nunca execute um script da internet sem ler,
inclusive estes.

Os arquivos que o `curl` entrega são o [`dist/base.sh`](dist/base.sh), o
[`dist/mautic7.sh`](dist/mautic7.sh) e o
[`dist/playahead.sh`](dist/playahead.sh) deste repositório, exatamente como
estão aqui. Você pode auditar no GitHub antes de baixar, e o cabeçalho de cada um traz
o número da versão e a data do build.

**Um instalador nunca chama o outro.** Se você rodar o do Mautic antes da base,
ele diz o que está faltando, mostra o comando pronto na tela e encerra sem
alterar nada. Foi escolha de projeto: um script que pede para ser lido antes de
rodar não deveria buscar e executar outro por conta própria.

Os dois precisam de root, mas **não escalam privilégio sozinhos**. Rodando sem
`sudo`, avisam e param.

## O que a base faz

Ela detecta sozinha em qual situação a sua VPS está.

**VPS zerada:** instala Docker, Docker Compose e Traefik.

**VPS que já tem Docker:** reaproveita o Docker e instala só o Traefik.

**VPS que já tem um proxy Traefik:** não toca nele. Mostra os nomes de rede,
entrypoint e certresolver que encontrou, e segue.

Se as portas 80 e 443 estiverem ocupadas por um servidor web instalado direto no
sistema, ela para e mostra quem está ocupando, em vez de tentar contornar.

## O que o instalador do Mautic faz

Confere que a base está pronta, identifica o proxy existente, confirma com você
os nomes de rede, entrypoint e certresolver, e sobe a stack do Mautic
reaproveitando o que já está lá.

Gera senhas aleatórias, aguarda os serviços ficarem saudáveis de verdade e mostra
no final a URL, o usuário e a senha de acesso.

O painel já nasce em português do Brasil, com fuso America/Sao_Paulo. A tela
de login ainda aparece em inglês: ver "Idioma e fuso horário".

No fim, testa se a VPS consegue enviar e-mail pelas portas 587 e 2587, e avisa
qual usar. Ver "E-mail (SMTP)".

## Onde ficam os arquivos

    /opt/playahead/mautic/docker-compose.yml
    /opt/playahead/mautic/.env
    /opt/playahead/mautic/credenciais.txt
    /opt/playahead/mautic/backups/          só depois de uma atualização

O `credenciais.txt` guarda o login do admin e as credenciais do banco, com
permissão restrita ao root. Ele **não é apagado** ao final: se você fechar o
terminal sem anotar a senha, ela não é recuperável de outro jeito. Copie para um
gerenciador de senhas assim que puder.

## Rodar de novo

O script é seguro para rodar mais de uma vez. Encontrando uma instalação
completa, ele reconhece o estado, reimprime os dados de acesso e oferece
reiniciar a stack. Ele nunca sobrescreve o `.env` nem toca no banco.

A única situação em que ele para é quando encontra uma instalação pela metade
(o volume do banco existe mas o `.env` sumiu, ou o contrário). Nesse caso
seguir em frente geraria um erro de autenticação difícil de diagnosticar, então
ele prefere explicar e sair.

## Atualizar

Cada instalador traz as versões que a Play Ahead testou. Para levar uma
instalação que já existe até elas, baixe o instalador de novo, leia e rode com
`--atualizar`:

    curl -sL https://get.playahead.com.br/mautic7 -o mautic7.sh
    less mautic7.sh
    sudo bash mautic7.sh --atualizar

A base (Traefik e Portainer) se atualiza do mesmo jeito, com o `base.sh`:

    sudo bash base.sh --atualizar

O que a atualização faz, nesta ordem:

1. Mostra de qual versão para qual vai, e pergunta se pode. O Enter vale "não".
2. Baixa as imagens novas, com o site ainda no ar.
3. Para o Mautic e faz o backup: o banco inteiro, o `docker-compose.yml`, o
   `.env`, a configuração e os temas e plugins instalados pelo painel.
4. Só então troca a versão. O Mautic novo aplica as migrações do banco sozinho.
5. Confere se o site abre e diz onde o backup ficou.

O que você precisa saber antes:

- **O site fica fora do ar durante a troca.** Alguns minutos; com banco grande,
  mais. Atualizar a base tira todos os sites da VPS do ar por alguns segundos.
- **Não há volta automática.** A migração do banco não desfaz. O caminho de
  volta é o backup, e os comandos para restaurar ficam no arquivo
  `COMO-RESTAURAR.txt`, dentro da pasta do backup. Se a atualização sair com
  erro, os mesmos comandos aparecem na tela.
- **O `docker-compose.yml` é regravado.** É a única situação em que o
  instalador sobrescreve esse arquivo, porque a versão mora nele. Se você o
  alterou à mão, a alteração não vai junto: o instalador avisa antes, e o
  arquivo antigo fica no backup. O `.env` nunca é tocado.
- **Plugins instalados pelo Marketplace precisam ser reinstalados.** Eles moram
  dentro do container, que é recriado. O instalador lista os nomes e guarda uma
  cópia no backup. Os temas enviados pelo painel são devolvidos sozinhos.
- **Se o terminal cair no meio**, rode o mesmo comando de novo: a atualização
  continua de onde parou e não refaz o backup.
- A atualização leva sempre para a versão recomendada do instalador que você
  baixou, nunca para uma mais nova. Se o que está instalado já é mais novo que
  ela, o instalador para e pede a versão mais recente dele.

Os backups ficam em `/opt/playahead/mautic/backups/` e em
`/opt/playahead/backups/`, legíveis só pelo root. O instalador não apaga backup:
quando tiver certeza de que está tudo certo, apague a pasta para liberar espaço.

## Opções

Da base:

    --acme-email=EMAIL           e-mail usado no Let's Encrypt
    --portainer-domain=DOMINIO   subdomínio do Portainer
    --sem-portainer              não instala o Portainer
    --skip-dns-check             pula a validação de DNS
    --no-swap                    não cria arquivo de swap
    --atualizar                  atualiza o Traefik e o Portainer (ver "Atualizar")
    --yes                        não interativo, sem nenhuma pergunta
    --help                       lista todas as opções
    --version                    mostra a versão e a data do build

Do instalador do Mautic:

    --domain=DOMINIO             domínio do Mautic
    --admin-email=EMAIL          e-mail do administrador
    --traefik-network=NOME       força o nome da rede do Traefik
    --traefik-entrypoint=NOME    força o nome do entrypoint
    --traefik-certresolver=NOME  força o nome do certresolver
    --no-certresolver            para quem termina o SSL fora da VPS
    --idioma=CODIGO              idioma do painel (padrão pt_BR)
    --fuso=FUSO                  fuso horário (padrão America/Sao_Paulo)
    --versao=recomendada         instala a versão testada pela Play Ahead (padrão)
    --versao=mais-nova           instala a mais nova do Mautic 7, sem teste
    --wizard                     não conclui a instalação, deixa o assistente web
    --skip-dns-check             pula a validação de DNS
    --atualizar                  atualiza um Mautic já instalado (ver "Atualizar")
    --yes                        não interativo, sem nenhuma pergunta
    --help                       lista todas as opções
    --version                    mostra a versão e a data do build

Com `--yes` e as flags necessárias, cada um roda do início ao fim sem perguntar
nada.

## Portainer

O Portainer é um painel para ver e mexer nos containers da VPS pelo navegador.
Ele faz parte da base e é instalado junto, sem flag nenhuma. O que ele pede é um
subdomínio próprio, apontando para a VPS, e a base pergunta isso no mesmo bloco
de perguntas do resto.

Não quer o Portainer? Aperte Enter na pergunta do subdomínio, ou rode a base com
`--sem-portainer`.

**A senha já vem pronta.** A base gera a senha do usuário `admin`, entrega ao
Portainer antes de ele subir, mostra no fim da instalação e guarda em:

    /opt/playahead/portainer/credenciais.txt

Por isso você não vai ver a tela de "setup token" que o Portainer mostra desde a
versão 2.43, nem o prazo de 5 minutos para criar o administrador. Abra o
endereço e entre com `admin` e a senha.

Quem entra no Portainer controla todos os containers da máquina. Guarde a senha
num gerenciador de senhas. Para trocá-la, use o próprio painel: editar o arquivo
`admin_password` daquela pasta não tem efeito depois da primeira subida.

## Usa Cloudflare?

Se o seu domínio está com a nuvenzinha laranja ligada, ele resolve para um IP do
Cloudflare e não para o da sua VPS. Isso está certo, e o script reconhece a
situação: ele avisa em vez de bloquear.

Só confira uma coisa no painel do Cloudflare: o modo de SSL precisa estar em
**Full (strict)**. Em modo Flexible o Mautic entra em laço de redirecionamento e
não abre.

## Memória

Em VPS de 2 GB sem swap, o Mautic pode ser encerrado pelo sistema durante a
instalação, sem mensagem de erro clara. Para evitar isso, **a base** cria um
arquivo de swap de 2 GB quando encontra menos de 3800 MB de RAM e nenhum swap
configurado. Ela avisa na tela quando faz isso, e `--no-swap` desliga o
comportamento.

## Limpar o cache

Limpar cache é a primeira coisa que se tenta quando algo estranho acontece no
Mautic. Nesta instalação, limpar o cache é reiniciar o serviço da web:

    cd /opt/playahead/mautic
    docker compose restart mautic_web

Ao subir, o container joga o cache fora e monta outro inteiro antes de voltar
a atender. Leva cerca de um minuto, e o site fica fora do ar nesse tempo: faça
num horário de pouco movimento. Temas e plugins instalados pelo painel não são
tocados. O comando também está no `credenciais.txt` da instalação, para não
depender de você achar esta página.

**Não use o `cache:clear`.** Com o site no ar, ele disputa a pasta com o
próprio Mautic: num teste ele falhou no meio, deixou o cache em pedaços e o
site passou a responder **erro 500**.

**Não recrie o container para limpar o cache** (`up -d --force-recreate`):
temas e plugins instalados pelo painel moram dentro dele e se perderiam.

Qualquer comando de console (`php bin/console`) vai **sempre com
`-u www-data`**. Sem ele o comando roda como root, deixa arquivos de root no
cache, e o Mautic passa a responder erro 500. Foi medido num teste: 30.737
arquivos de root e o site fora do ar. Se isso já aconteceu, reiniciar também
recupera: ao subir, o container devolve os arquivos ao `www-data`.

## Idioma e fuso horário

A instalação já nasce em português do Brasil e com fuso `America/Sao_Paulo`,
sem nenhum passo manual.

**A tela de login e as telas de usuários saem em inglês.** O pacote oficial de
tradução `pt_BR` da Mautic não traz, desde outubro de 2026, o arquivo de
mensagens do módulo de usuários. O resto do painel aparece em português. Não é
falha da instalação, e volta ao normal quando o pacote oficial for corrigido.

Para outro idioma ou outro fuso:

    sudo bash mautic7.sh --idioma=es --fuso=Europe/Madrid

Os códigos de idioma válidos são os do
[manifesto oficial do Mautic](https://language-packs.mautic.com/manifest.json).
Informando um código que não existe lá, o script avisa e segue em inglês, em
vez de parar a instalação.

## E-mail (SMTP)

O script não configura o envio de e-mail, mas no fim da instalação ele testa
se a VPS consegue sair pelas portas 587 e 2587. **Vários provedores bloqueiam a
saída nas portas 25, 465 e 587, e a DigitalOcean é um deles.** O painel do
Mautic aceita a configuração mesmo assim, o envio falha, e nada na tela diz
por quê.

No Amazon SES, com a 587 bloqueada, use a porta **2587** (STARTTLS) ou a
**2465** (TLS). O resultado do teste fica no `credenciais.txt`.

Depois de alterar a configuração de e-mail no painel, os workers que fazem o
envio passam a usá-la **em até 5 minutos**, sozinhos. Para valer na hora:

    cd /opt/playahead/mautic
    docker compose restart mautic_worker

Confira o envio pelo log, e não pelo histórico do contato: o Mautic marca
"Email Enviado" mesmo quando o servidor de e-mail recusou a mensagem.

## O que o script NÃO faz

Não configura SMTP, Amazon SES, SPF, DKIM, DMARC nem aquecimento de domínio.

Essa é a parte que define se o seu e-mail chega na caixa de entrada ou no spam,
e ela não se resolve com script. Se precisar de ajuda com isso, veja o
[treinamento Impulse](https://impulse.playahead.com.br/) ou fale com a equipe
para uma instalação e configuração completa.

Também não apaga nada. Não roda `docker system prune`, não sobrescreve
configuração existente e não altera um Traefik que já esteja rodando sem
perguntar antes.

## Privacidade

O script não coleta nem envia nenhuma informação. Não há telemetria, contagem de
instalações nem registro de IP.

Para instalar, ele precisa falar com estes servidores, e nenhum é da Play
Ahead:

- `download.docker.com`: os pacotes do Docker e a chave que os assina. A
  impressão digital da chave é conferida antes de ser aceita.
- Docker Hub (`hub.docker.com` e o registro de imagens): as imagens do Traefik,
  do Portainer, do MariaDB e do Mautic, e a lista pública de versões do
  Mautic 7.
- `language-packs.mautic.com`: a lista de idiomas e o pacote do idioma do
  painel.
- `email-smtp.us-east-1.amazonaws.com`, do Amazon SES: o teste de SMTP do fim
  da instalação abre uma conexão e fecha, sem enviar nada.
- `api.ipify.org`: só quando a VPS está atrás de NAT e o IP público não aparece
  na placa de rede.
- Let's Encrypt: recebe o domínio e o e-mail que você informou, para emitir o
  certificado SSL. O e-mail vai para a Let's Encrypt, não para a Play Ahead.

A tela avisa de cada consulta. O que esses servidores veem é o IP da VPS, como
em qualquer download.

Se quiser receber avisos de novas versões, correções e conteúdos da Play Ahead
sobre automação de marketing, a inscrição é voluntária em
[playahead.com.br/avisos](https://playahead.com.br/avisos).

## Aviso

Este script altera a configuração do servidor onde é executado: instala pacotes,
cria containers, volumes e regras de rede. Execute apenas em servidor dedicado a
esta finalidade e do qual você tenha cópia de segurança.

O software é fornecido "como está", sem garantia de qualquer espécie. A Play
Ahead não se responsabiliza por perda de dados, indisponibilidade ou danos
decorrentes do uso.

## Licença

MIT. O texto e o titular estão no arquivo [LICENSE](LICENSE).
