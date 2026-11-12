#!/usr/bin/env bash
# shellcheck shell=bash
#
# Mostra um tema na tela, sem instalar nada e sem tocar na máquina.
#
#     bash docs/visual/previa.sh
#         o tema em uso, que é o bloco TEMA do lib/ui.sh
#
#     bash docs/visual/previa.sh docs/visual/tema-1-marca-na-moldura.sh
#         um dos temas guardados
#
# Carrega o lib/ui.sh, põe o tema pedido por cima e desenha as telas
# que mais mudam de um tema para outro: o cabeçalho de um instalador,
# as etapas com os três resultados, a tela de confirmação, o quadro
# final e o menu. Os dados são de exemplo.
#
# Para guardar a tela num arquivo de texto, sem cor:
#
#     NO_COLOR=1 bash docs/visual/previa.sh > tela.txt

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# shellcheck source=lib/ui.sh
source lib/ui.sh
# shellcheck source=lib/menu_main.sh
source lib/menu_main.sh

tema="${1:-}"
if [[ -n "$tema" ]]; then
	if [[ ! -f "$tema" ]]; then
		printf 'Não achei o tema: %s\n' "$tema" >&2
		exit 1
	fi

	# shellcheck disable=SC1090
	source "$tema"
fi

# Sem perguntas: a prévia só desenha.
ui_init 1

# O cabeçalho faz uma pausa para a pessoa ler o aviso. Aqui não há o
# que esperar.
sleep() { :; }

titulo_do_menu="$PA_TITULO"

# ------------------------------------------------------------
# Um instalador de ferramenta
# ------------------------------------------------------------

PA_TITULO=""
PA_FERRAMENTA="Mautic 7 em Docker"
ui_cabecalho

ui_etapas 8

ui_etapa "Conferindo o servidor"
ui_ok "Bash 5.2"
ui_ok "Executando como root"
ui_ok "Ubuntu 24.04"
ui_aviso "RAM: 1967 MB, abaixo dos 4 GB recomendados"
ui_detalhe "O swap será conferido adiante."

ui_etapa "Conferindo a base"
ui_passo "Procurando o Docker e o Traefik"
ui_erro "Falta a base desta VPS: Docker e Traefik"
ui_detalhe "Instale a base e rode este instalador de novo."

ui_resumo "Confira antes de começar" \
	"Domínio" "https://mautic.exemplo.com.br" informado \
	"E-mail do admin" "admin@exemplo.com.br" informado \
	"DNS" "aponta para esta VPS" detectado \
	"Rede do Traefik" "traefik_public" detectado \
	"Versão" "Mautic 7.2.2, a recomendada" padrao

ui_quadro "Mautic instalado e no ar" \
	$'Endereço\thttps://mautic.exemplo.com.br' \
	$'E-mail\tadmin@exemplo.com.br' \
	$'Senha\tsenha-de-exemplo-que-nao-existe' \
	"" \
	"Guarde num gerenciador de senhas."

# ------------------------------------------------------------
# O menu
# ------------------------------------------------------------

PA_TITULO="$titulo_do_menu"
PA_FERRAMENTA="Menu de instaladores"
ui_cabecalho

# A marca de instalado da Base é este próprio arquivo, que existe,
# para a palavra "instalado" aparecer na prévia.
menu_registrar "base.sh" "$PA_VERSAO" "Base" \
	"Docker, Traefik e Portainer. Uma vez por VPS." \
	"infraestrutura" "${BASH_SOURCE[0]}"
menu_registrar "mautic7.sh" "$PA_VERSAO" "Mautic 7" \
	"Precisa da base instalada." \
	"marketing" "/caminho/que/nao/existe"

menu_listar
