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

O script será hospedado em domínio próprio da Play Ahead e executado assim:

    curl -sL https://get.playahead.com.br/mautic7 -o install.sh
    less install.sh
    bash install.sh

O tutorial mostra o download separado da execução de propósito, para ensinar a
pessoa a ler um script antes de rodar.

## Requisitos funcionais

O script precisa funcionar em dois cenários e decidir sozinho em qual está:

1. **VPS zerada.** Instala Docker, Docker Compose plugin, Traefik e Portainer,
   cria a rede do proxy e só então sobe o Mautic.
2. **Máquina que já tem tudo.** Detecta o Docker e o Traefik existentes e sobe
   apenas o Mautic, reaproveitando o proxy que já está lá.

No cenário 2, nada pode ser assumido. Nomes de entrypoint, de certresolver e de
rede do Traefik são arbitrários e variam por instalação (quem usou outros
instaladores populares tem nomes diferentes de `websecure`, `letsencrypt` e
`traefik_public`). O script precisa inspecionar o container do Traefik em
execução, extrair os valores reais, mostrar o que encontrou e pedir confirmação
antes de aplicar. Se cravar os nomes padrão, o container sobe, o Mautic funciona
e o domínio devolve 404 sem nenhuma mensagem de erro.

## Checagens obrigatórias antes de qualquer instalação

Falhar cedo, com mensagem clara em português, é o requisito mais importante do
projeto. Cada falha silenciosa aqui vira comentário de "não funcionou" no vídeo.

- Sistema operacional suportado (definir a lista e barrar o resto)
- Usuário root ou sudo
- RAM mínima e espaço em disco
- Portas 80 e 443 livres (no cenário 1)
- Arquitetura x86_64
- O domínio informado resolve para o IP público desta máquina.
  Esta é a checagem que mais economiza suporte. Se o DNS aponta para outro
  lugar, o Let's Encrypt falha e a pessoa culpa o script. Mostrar os dois IPs
  na mensagem de erro.

## Conclusão da instalação: via CLI

O script conclui a instalação com `mautic:install`, gerando usuário e senha de
admin, e entrega o painel pronto para login.

Motivo: um instalador que para antes do fim quebra a idempotência e reintroduz
o erro de digitação de credenciais de banco que o próprio script acabou de
resolver. Além disso, o mesmo script roda nas instalações do serviço pago, onde
preencher formulário no navegador a cada cliente não escala.

Uma flag `--wizard` pula o `mautic:install` e deixa o assistente web aparecer,
para quem quiser acompanhar o processo. É um `if` no final, não um caminho
paralelo.

Cuidados obrigatórios:

- Senha de admin gerada com `openssl rand`, nunca fixa.
- Não passar a senha de forma que ela apareça no histórico do shell nem em `ps`.
  Usar variável de ambiente ou arquivo temporário com permissão restrita,
  removido logo depois.
- Detectar instalação já existente e não reinstalar por cima.
- Imprimir URL, e-mail do admin, senha e caminho do `.env` no bloco final.

## Comportamento esperado

- Idempotente. Rodar duas vezes não pode destruir banco nem sobrescrever `.env`.
- Senhas geradas com `openssl rand`, nunca fixas no código.
- Esperar o healthcheck responder de verdade antes de declarar sucesso. Nada de
  `sleep 120`.
- Mensagens em português, sem jargão desnecessário.
- Passar em `shellcheck` sem warnings.

### Nada destrutivo

Este é um requisito de proteção, não de conveniência. Um script que não destrói
nada raramente vira problema, jurídico ou de reputação.

- Nunca sobrescrever `.env` existente.
- Nunca executar `docker system prune` ou equivalente.
- Nunca alterar configuração de Traefik que já está rodando sem avisar e pedir
  confirmação explícita.
- Diante de instalação anterior detectada, parar e explicar, em vez de seguir.

## Licença e aviso legal

Licença MIT. Arquivo `LICENSE` na raiz do repositório. Sem licença explícita,
ninguém tem permissão formal de redistribuir ou modificar o script, e ele vai
circular.

O `install.sh` traz este bloco como cabeçalho e o imprime na tela no início da
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

O arquivo `templates/docker-compose-mautic7-playahead.yml` já está corrigido e
parametrizado. Ele expõe `TRAEFIK_NETWORK`, `TRAEFIK_ENTRYPOINT` e
`TRAEFIK_CERTRESOLVER` como variáveis com default, exatamente para atender o
cenário 2. O script gera o `.env` que alimenta essas variáveis.

Serviços: MariaDB, mautic_web, mautic_cron, mautic_worker.

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

## Estrutura pretendida

    install.sh              orquestrador
    LICENSE                 MIT
    lib/checks.sh           pré-checagens
    lib/docker.sh           instalação do Docker
    lib/traefik.sh          instalação e detecção do Traefik
    lib/portainer.sh        instalação do Portainer
    lib/mautic.sh           geração do .env e subida da stack
    lib/ui.sh               cores, prompts, mensagens
    templates/              arquivos docker-compose

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
