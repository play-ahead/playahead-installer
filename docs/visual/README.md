# Visual do instalador

O que dá a cara do Play Ahead Installer está num bloco só, no topo do
`lib/ui.sh`, entre as linhas `TEMA` e `FIM DO TEMA`: o logo, as cores, os
símbolos, a moldura e o formato dos títulos. O resto do código desenha a tela
a partir dessas variáveis.

Foram desenhados três temas. O instalador usa o 2. Os outros dois ficam
guardados aqui, prontos, para trocar depois sem refazer o desenho.

| Tema | Arquivo | Como é |
|---|---|---|
| 1 | `tema-1-marca-na-moldura.sh` | a marca de dois triângulos numa moldura fina, com o nome ao lado |
| 2 | o bloco `TEMA` do `lib/ui.sh` | o nome em letras de bloco, entre duas linhas. **Em uso** |
| 3 | `tema-3-traco-fino.sh` | o nome em letras de traço fino, com uma barra à esquerda |

## Ver um tema na tela

Não instala nada e não toca na máquina. Na raiz do repositório:

    bash docs/visual/previa.sh
    bash docs/visual/previa.sh docs/visual/tema-1-marca-na-moldura.sh
    bash docs/visual/previa.sh docs/visual/tema-3-traco-fino.sh

Sem argumento, mostra o tema em uso. As telas são de exemplo: o cabeçalho de
um instalador, as etapas com os três resultados, a tela de confirmação, o
quadro final e o menu.

## Trocar de tema

1. Abra o arquivo do tema escolhido e copie do comentário `TEMA` até o
   `FIM DO TEMA`.
2. No `lib/ui.sh`, cole por cima do bloco que está entre as mesmas duas
   marcas.
3. Para não perder o tema que saiu, salve o bloco antigo num arquivo aqui,
   com o mesmo cabeçalho de três linhas dos outros (`tema-2-letras-em-bloco.sh`,
   por exemplo).
4. Rode `./build.sh`. Ele regenera o `dist/` e confere se os temas guardados
   declaram as mesmas variáveis do bloco em uso.
5. Faça o commit do `lib/ui.sh` junto com o `dist/`.

Não é preciso mexer em mais nada. O teste fixo lê o formato do título de
etapa do próprio `dist/`, então o contador continua conferido com qualquer
tema.

## Criar um tema

Copie um dos arquivos e mude as variáveis. O que cada uma faz está no
comentário em cima dela. Três regras do projeto valem para qualquer tema:

- Poucas cores. A da marca fica na identidade (logo, linhas do cabeçalho,
  contador de etapas, números do menu). Verde, amarelo e vermelho dizem o
  resultado de cada passo, e mais nada.
- Tem de caber em 80 colunas e funcionar sem cor: saída para arquivo e
  `NO_COLOR` não levam código de cor nenhum.
- O logo é escrito com os caracteres que vão para a tela, para quem lê o
  arquivo antes de rodar ver o desenho.

Uma variável nova no bloco do `lib/ui.sh` tem de entrar também nos temas
guardados: o `./build.sh` para e avisa quando eles ficam diferentes.

## As telas

Saída de `NO_COLOR=1 bash docs/visual/previa.sh`, sem as cores. Na tela de
verdade, o logo, as linhas do cabeçalho, o contador de etapas e os números
do menu saem no roxo da marca.

### Tema 2: letras em bloco, entre duas linhas (em uso)

      ────────────────────────────────────────────────────────────────────

       █▀█ █   █▀█ █ █   █▀█ █ █ █▀▀ █▀█ █▀▄
       █▀▀ █   █▀█ ▀█▀   █▀█ █▀█ █▀▀ █▀█ █ █
       ▀   ▀▀▀ ▀ ▀  ▀    ▀ ▀ ▀ ▀ ▀▀▀ ▀ ▀ ▀▀

       Mautic 7 em Docker                                    versão 0.1.0
      ────────────────────────────────────────────────────────────────────
       playahead.com.br   Licença MIT. Consulte o arquivo LICENSE.

       (aqui entra o aviso, igual nos três temas)

       [1/8] Conferindo o servidor
       ✓ Bash 5.2
       ✓ Executando como root
       ✓ Ubuntu 24.04
       ! RAM: 1967 MB, abaixo dos 4 GB recomendados
         O swap será conferido adiante.

       [2/8] Conferindo a base
       › Procurando o Docker e o Traefik
       ✗ Falta a base desta VPS: Docker e Traefik
         Instale a base e rode este instalador de novo.

       [3/8] Confira antes de começar
       > Domínio             https://mautic.exemplo.com.br
       > E-mail do admin     admin@exemplo.com.br
         DNS                 aponta para esta VPS
         Rede do Traefik     traefik_public
         Versão              Mautic 7.2.2, a recomendada

         > veio de você. Confira estes com atenção.

      ────────────────────────────────────────────────────────────────────

       Mautic instalado e no ar

       Endereço   https://mautic.exemplo.com.br
       E-mail     admin@exemplo.com.br
       Senha      senha-de-exemplo-que-nao-existe

       Guarde num gerenciador de senhas.

      ────────────────────────────────────────────────────────────────────

      ────────────────────────────────────────────────────────────────────

       █▀█ █   █▀█ █ █   █▀█ █ █ █▀▀ █▀█ █▀▄
       █▀▀ █   █▀█ ▀█▀   █▀█ █▀█ █▀▀ █▀█ █ █
       ▀   ▀▀▀ ▀ ▀  ▀    ▀ ▀ ▀ ▀ ▀▀▀ ▀ ▀ ▀▀

       Play Ahead Installer                                  versão 0.1.0
      ────────────────────────────────────────────────────────────────────
       playahead.com.br   Licença MIT. Consulte o arquivo LICENSE.

       (aqui entra o aviso, igual nos três temas)

       Instaladores
      ────────────────────────────────────────────────────────────────────
       1  Base       instalado   Docker, Traefik e Portainer. Uma vez por VPS.
       2  Mautic 7               Precisa da base instalada.
       0  Sair
      ────────────────────────────────────────────────────────────────────
         Para só gravar os instaladores e ler antes: --extrair

### Tema 1: a marca numa moldura fina

      ┌────────────────────────────────────────────────────────────────────┐
      │                                                                    │
      │   ██▄▄      ██▄▄                                                   │
      │   ██████▄▄  ██████▄▄     P L A Y   A H E A D                       │
      │   ██████▀▀  ██████▀▀     Mautic 7 em Docker                        │
      │   ██▀▀      ██▀▀         versão 0.1.0                              │
      │                                                                    │
      └────────────────────────────────────────────────────────────────────┘

      playahead.com.br
      Licença MIT. Consulte o arquivo LICENSE.

      (aqui entra o aviso, igual nos três temas)

      1 de 8  Conferindo o servidor
      ──────────────────────────────────────────────────────────────────────
        ✓ Bash 5.2
        ✓ Executando como root
        ✓ Ubuntu 24.04
        ! RAM: 1967 MB, abaixo dos 4 GB recomendados
          O swap será conferido adiante.

      2 de 8  Conferindo a base
      ──────────────────────────────────────────────────────────────────────
        › Procurando o Docker e o Traefik
        ✗ Falta a base desta VPS: Docker e Traefik
          Instale a base e rode este instalador de novo.

      3 de 8  Confira antes de começar
      ──────────────────────────────────────────────────────────────────────
        > Domínio             https://mautic.exemplo.com.br
        > E-mail do admin     admin@exemplo.com.br
          DNS                 aponta para esta VPS
          Rede do Traefik     traefik_public
          Versão              Mautic 7.2.2, a recomendada

          > veio de você. Confira estes com atenção.

      ┌────────────────────────────────────────────────────────────────────┐
      │                                                                    │
      │   Mautic instalado e no ar                                         │
      │                                                                    │
      │   Endereço   https://mautic.exemplo.com.br                         │
      │   E-mail     admin@exemplo.com.br                                  │
      │   Senha      senha-de-exemplo-que-nao-existe                       │
      │                                                                    │
      │   Guarde num gerenciador de senhas.                                │
      │                                                                    │
      └────────────────────────────────────────────────────────────────────┘

      ┌────────────────────────────────────────────────────────────────────┐
      │                                                                    │
      │   ██▄▄      ██▄▄                                                   │
      │   ██████▄▄  ██████▄▄     P L A Y   A H E A D                       │
      │   ██████▀▀  ██████▀▀     Play Ahead Installer                      │
      │   ██▀▀      ██▀▀         versão 0.1.0                              │
      │                                                                    │
      └────────────────────────────────────────────────────────────────────┘

      playahead.com.br
      Licença MIT. Consulte o arquivo LICENSE.

      (aqui entra o aviso, igual nos três temas)

      Instaladores
      ──────────────────────────────────────────────────────────────────────
        1  Base       instalado   Docker, Traefik e Portainer. Uma vez por VPS.
        2  Mautic 7               Precisa da base instalada.
        0  Sair

          Para só gravar os instaladores e ler antes: --extrair

### Tema 3: letras de traço fino, com uma barra à esquerda

      ▌ ┌─┐┬  ┌─┐┬ ┬  ┌─┐┬ ┬┌─┐┌─┐┌┬┐
      ▌ ├─┘│  ├─┤└┬┘  ├─┤├─┤├┤ ├─┤ ││
      ▌ ┴  ┴─┘┴ ┴ ┴   ┴ ┴┴ ┴└─┘┴ ┴─┴┘
      ▌
      ▌ Mautic 7 em Docker
      ▌ versão 0.1.0
      ▌ playahead.com.br
      ▌ Licença MIT. Consulte o arquivo LICENSE.

        (aqui entra o aviso, igual nos três temas)

      ▌ Conferindo o servidor  etapa 1 de 8
        ✓ Bash 5.2
        ✓ Executando como root
        ✓ Ubuntu 24.04
        ! RAM: 1967 MB, abaixo dos 4 GB recomendados
          O swap será conferido adiante.

      ▌ Conferindo a base  etapa 2 de 8
        › Procurando o Docker e o Traefik
        ✗ Falta a base desta VPS: Docker e Traefik
          Instale a base e rode este instalador de novo.

      ▌ Confira antes de começar  etapa 3 de 8
        > Domínio             https://mautic.exemplo.com.br
        > E-mail do admin     admin@exemplo.com.br
          DNS                 aponta para esta VPS
          Rede do Traefik     traefik_public
          Versão              Mautic 7.2.2, a recomendada

          > veio de você. Confira estes com atenção.

      ────────────────────────────────────────────────────────────────────

        Mautic instalado e no ar

        Endereço   https://mautic.exemplo.com.br
        E-mail     admin@exemplo.com.br
        Senha      senha-de-exemplo-que-nao-existe

        Guarde num gerenciador de senhas.

      ────────────────────────────────────────────────────────────────────

      ▌ ┌─┐┬  ┌─┐┬ ┬  ┌─┐┬ ┬┌─┐┌─┐┌┬┐
      ▌ ├─┘│  ├─┤└┬┘  ├─┤├─┤├┤ ├─┤ ││
      ▌ ┴  ┴─┘┴ ┴ ┴   ┴ ┴┴ ┴└─┘┴ ┴─┴┘
      ▌
      ▌ Play Ahead Installer
      ▌ versão 0.1.0
      ▌ playahead.com.br
      ▌ Licença MIT. Consulte o arquivo LICENSE.

        (aqui entra o aviso, igual nos três temas)

      ▌ Instaladores

        1)  Base       instalado   Docker, Traefik e Portainer. Uma vez por VPS.
        2)  Mautic 7               Precisa da base instalada.
        0)  Sair

          Para só gravar os instaladores e ler antes: --extrair
