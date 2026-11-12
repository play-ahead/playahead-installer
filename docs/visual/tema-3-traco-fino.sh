# shellcheck shell=bash
# shellcheck disable=SC2034
#
# Tema 3 do Play Ahead Installer: letras de traço fino, com uma barra
# à esquerda.
#
# Não é usado pelo instalador. Fica guardado para o dia em que se
# quiser trocar o visual sem refazer o desenho. Como trocar, e como
# ver na tela antes, está em docs/visual/README.md.

# ============================================================
# TEMA
#
# A cara do instalador está toda neste bloco: o logo, as cores, os
# símbolos, a moldura e o formato dos títulos. Trocar o visual é
# mexer só aqui. O resto do arquivo desenha a tela a partir destas
# variáveis, e nenhuma outra lib escolhe cor ou caractere.
#
# Há outros dois temas prontos em docs/visual/, cada um com este
# mesmo bloco preenchido de outro jeito. Para trocar, copie o bloco
# de lá por cima deste, do "TEMA" ao "FIM DO TEMA", e rode
# ./build.sh. Para ver um tema na tela sem instalar nada:
#
#     bash docs/visual/previa.sh docs/visual/tema-1-marca-na-moldura.sh
#
# Tema em uso: 3, letras de traço fino com uma barra à esquerda.
# ============================================================

# O logo, como aparece na tela. Está escrito com os mesmos caracteres
# que vão para o terminal, para quem lê este arquivo antes de rodar
# ver o desenho, e não uma lista de códigos.
PA_TEMA_LOGO=(
	'┌─┐┬  ┌─┐┬ ┬  ┌─┐┬ ┬┌─┐┌─┐┌┬┐'
	'├─┘│  ├─┤└┬┘  ├─┤├─┤├┤ ├─┤ ││'
	'┴  ┴─┘┴ ┴ ┴   ┴ ┴┴ ┴└─┘┴ ┴─┴┘'
)

# O nome por extenso, para o tema em que o logo é um desenho e o nome
# precisa vir escrito ao lado. Aqui o logo já é o nome.
PA_TEMA_NOME=""

# Como o logo é apresentado:
#   linhas   entre uma linha em cima e outra embaixo
#   caixa    dentro de uma moldura fechada, com o nome ao lado
#   barra    com uma barra vertical à esquerda
PA_TEMA_CABECALHO="barra"

# O quadro final, com o endereço e as senhas: "linhas" ou "caixa".
PA_TEMA_QUADRO="linhas"

# Largura do que é desenhado, sem a margem. Com a margem e as bordas
# cabe nas 80 colunas de um terminal padrão.
PA_TEMA_LARGURA=68

# Margens, em colunas: onde começam as linhas e as molduras, os
# títulos, e o que acontece dentro de cada etapa. O detalhe de cada
# coisa fica duas colunas depois.
PA_TEMA_MARGEM_MOLDURA=2
PA_TEMA_MARGEM_TITULO=2
PA_TEMA_MARGEM_ITEM=4

# Título de etapa. {n} é o número da etapa e {t} o total. O que vem
# antes do título sai na cor da marca; o que vem depois, apagado. O
# teste fixo lê estas duas linhas para conferir o contador.
PA_TEMA_ETAPA_ANTES="▌ "
PA_TEMA_ETAPA_DEPOIS="  etapa {n} de {t}"

# 1 para passar uma linha embaixo do título de etapa.
PA_TEMA_ETAPA_LINHA=0

# Título sem número: o que vem antes dele, e se leva linha embaixo.
PA_TEMA_SECAO_ANTES="▌ "
PA_TEMA_SECAO_LINHA=0

# Lista do menu: o número de cada item ({n}), e se a lista fecha com
# outra linha.
PA_TEMA_LISTA_NUMERO="{n})"
PA_TEMA_LISTA_FECHA=0

# Símbolos: o passo em andamento, os três resultados, e a marca do
# que veio da pessoa na tela de confirmação.
PA_TEMA_SIMBOLO_PASSO="›"
PA_TEMA_SIMBOLO_OK="✓"
PA_TEMA_SIMBOLO_AVISO="!"
PA_TEMA_SIMBOLO_ERRO="✗"
PA_TEMA_SIMBOLO_INFORMADO=">"

# Peças das linhas e da moldura. Os cantos na ordem: de cima à
# esquerda, de cima à direita, de baixo à esquerda, de baixo à
# direita.
PA_TEMA_TRACO="─"
PA_TEMA_LADO="│"
PA_TEMA_CANTOS=("┌" "┐" "└" "┘")
PA_TEMA_BARRA="▌"

# Cores, em códigos ANSI: o que vai entre "ESC[" e "m". São poucas de
# propósito. A da marca fica só na identidade: o logo, a barra, o
# contador de etapas e os números do menu. Verde, amarelo e vermelho
# dizem o resultado de cada passo, e mais nada. O resto é texto
# normal, em negrito ou apagado.
#
# A cor da marca e o cinza do texto apagado só existem na paleta de
# 256 cores. Terminal que não a anuncia recebe as "BASICA", das 8
# cores. Sem terminal, ou com NO_COLOR, não sai cor nenhuma.
PA_TEMA_COR_MARCA="38;5;135"
PA_TEMA_COR_MARCA_BASICA="0;35"
PA_TEMA_COR_FRACA="38;5;245"
PA_TEMA_COR_FRACA_BASICA="0;90"
PA_TEMA_COR_OK="0;32"
PA_TEMA_COR_AVISO="0;33"
PA_TEMA_COR_ERRO="1;31"
PA_TEMA_COR_DESTAQUE="1"

# ============================================================
# FIM DO TEMA
# ============================================================
