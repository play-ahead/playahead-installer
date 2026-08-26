# Play Ahead Installer

Instalador de Mautic 7 em Docker para VPS, mantido pela
[Play Ahead](https://playahead.com.br).

Sobe uma stack completa e pronta para produção: Mautic 7 (web, cron e workers),
MariaDB, Traefik com certificado SSL automático e, opcionalmente, Portainer.

## Requisitos

- VPS com Ubuntu, arquitetura x86_64
- Acesso root ou sudo
- 2 GB de RAM no mínimo (4 GB recomendado)
- Um domínio ou subdomínio apontando para o IP da VPS

O apontamento de DNS precisa estar feito **antes** de rodar o script. Sem isso o
certificado SSL não é emitido.

## Como usar

Baixe, leia e execute:

    curl -sL https://get.playahead.com.br/mautic7 -o install.sh
    less install.sh
    bash install.sh

O passo do `less` não é enfeite. Nunca execute um script da internet sem ler,
inclusive este.

## O que o script faz

Ele detecta sozinho em qual situação a sua VPS está.

**VPS zerada:** instala Docker, Docker Compose, Traefik e sobe o Mautic.

**VPS que já tem Docker e Traefik:** identifica o proxy existente, confirma os
nomes de rede, entrypoint e certresolver com você, e sobe apenas o Mautic
reaproveitando o que já está lá.

Em ambos os casos o script gera senhas aleatórias, aguarda os serviços ficarem
saudáveis de verdade e mostra no final a URL, o usuário e a senha de acesso.

## Opções

    bash install.sh --wizard      # não conclui a instalação, deixa o assistente web do Mautic
    bash install.sh --portainer   # instala o Portainer junto (exige subdomínio próprio)
    bash install.sh --help        # lista todas as opções

## O que o script NÃO faz

Não configura SMTP, Amazon SES, SPF, DKIM, DMARC nem aquecimento de domínio.

Essa é a parte que define se o seu e-mail chega na caixa de entrada ou no spam,
e ela não se resolve com script. Se precisar de ajuda com isso, veja o
[treinamento Impulse](https://impulse.playahead.com.br/) ou fale com a equipe
para uma instalação e configuração completa.

## Privacidade

O script não coleta nem envia nenhuma informação. Não há telemetria, contagem de
instalações nem registro de IP.

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

MIT. Consulte o arquivo [LICENSE](LICENSE).

Fabio Roger de Oliveira ME, CNPJ 31.176.090/0001-08.
