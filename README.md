# Play Ahead Installer

Instalador de Mautic 7 em Docker para VPS, mantido pela
[Play Ahead](https://playahead.com.br).

Sobe uma stack completa e pronta para produção: Mautic 7 (web, cron e workers),
MariaDB, Traefik com certificado SSL automático e, opcionalmente, Portainer.

Este repositório reúne os instaladores da Play Ahead. Hoje só o do Mautic 7
existe; Chatwoot, Typebot e Evolution API entram depois, cada um com o seu
próprio arquivo em `dist/`.

## Requisitos

- VPS com Ubuntu 22.04 ou 24.04, arquitetura x86_64
- Acesso root ou sudo
- 2 GB de RAM no mínimo (4 GB recomendado)
- Um domínio ou subdomínio apontando para o IP da VPS

Versões de Ubuntu LTS mais novas que essas não são bloqueadas: o script avisa
que não foram testadas e pergunta se você quer continuar. Debian 12 entra numa
versão futura, depois de testado.

O apontamento de DNS precisa estar feito **antes** de rodar o script. Sem isso o
certificado SSL não é emitido.

## Como usar

Baixe, leia e execute:

    curl -sL https://get.playahead.com.br/mautic7 -o mautic7.sh
    less mautic7.sh
    sudo bash mautic7.sh

O passo do `less` não é enfeite. Nunca execute um script da internet sem ler,
inclusive este.

O arquivo que o `curl` entrega é o
[`dist/mautic7.sh`](dist/mautic7.sh) deste repositório, exatamente como está
aqui. Você pode auditar no GitHub antes de baixar, e o cabeçalho do arquivo traz
o número da versão e a data do build.

O script precisa de root, mas **não escala privilégio sozinho**. Se você rodar
sem `sudo`, ele avisa e para.

## O que o script faz

Ele detecta sozinho em qual situação a sua VPS está.

**VPS zerada:** instala Docker, Docker Compose, Traefik e sobe o Mautic.

**VPS que já tem Docker, mas não tem proxy:** instala só o Traefik e o Mautic.

**VPS que já tem Docker e Traefik:** identifica o proxy existente, confirma os
nomes de rede, entrypoint e certresolver com você, e sobe apenas o Mautic
reaproveitando o que já está lá.

Em ambos os casos o script gera senhas aleatórias, aguarda os serviços ficarem
saudáveis de verdade e mostra no final a URL, o usuário e a senha de acesso.

Se as portas 80 e 443 estiverem ocupadas por um servidor web instalado direto no
sistema, o script para e mostra quem está ocupando, em vez de tentar contornar.

## Onde ficam os arquivos

    /opt/playahead/mautic/docker-compose.yml
    /opt/playahead/mautic/.env
    /opt/playahead/mautic/credenciais.txt

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

## Opções

    --domain=DOMINIO             domínio do Mautic
    --admin-email=EMAIL          e-mail do administrador
    --acme-email=EMAIL           e-mail usado no Let's Encrypt
    --traefik-network=NOME       força o nome da rede do Traefik
    --traefik-entrypoint=NOME    força o nome do entrypoint
    --traefik-certresolver=NOME  força o nome do certresolver
    --no-certresolver            para quem termina o SSL fora da VPS
    --wizard                     não conclui a instalação, deixa o assistente web
    --portainer                  instala o Portainer ao final
    --portainer-domain=DOMINIO   subdomínio do Portainer
    --skip-dns-check             pula a validação de DNS
    --no-swap                    não cria arquivo de swap
    --yes                        não interativo, sem nenhuma pergunta
    --help                       lista todas as opções
    --version                    mostra a versão e a data do build

Com `--yes` e as flags necessárias, o script roda do início ao fim sem
perguntar nada.

## Usa Cloudflare?

Se o seu domínio está com a nuvenzinha laranja ligada, ele resolve para um IP do
Cloudflare e não para o da sua VPS. Isso está certo, e o script reconhece a
situação: ele avisa em vez de bloquear.

Só confira uma coisa no painel do Cloudflare: o modo de SSL precisa estar em
**Full (strict)**. Em modo Flexible o Mautic entra em laço de redirecionamento e
não abre.

## Memória

Em VPS de 2 GB sem swap, o Mautic pode ser encerrado pelo sistema durante a
instalação, sem mensagem de erro clara. Para evitar isso, o script cria um
arquivo de swap de 2 GB quando encontra menos de 4 GB de RAM e nenhum swap
configurado. Ele avisa na tela quando faz isso, e `--no-swap` desliga o
comportamento.

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

O e-mail pedido durante a instalação é usado apenas para emitir o certificado
SSL e vai para a Let's Encrypt, não para a Play Ahead.

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
