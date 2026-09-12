#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/menu_main.sh
# Menu: lista as ferramentas e chama o instalador escolhido.
#
# Depende de lib/ui.sh e das funções que o build.sh embute.
#
# O MENU CONTÉM OS INSTALADORES, não os busca.
#
# Essa é a decisão que faz o menu conviver com a regra de que um
# instalador não baixa nem executa outro. O build.sh embute o
# dist/base.sh e o dist/mautic7.sh aqui dentro, como heredoc
# citado — mesmo mecanismo já validado para o template do compose.
# Escolhido o número, o menu grava o instalador no diretório atual
# e o executa.
#
# O que se ganha com isso:
#
#   - nada é buscado na rede, então um download e um `less` bastam
#     para auditar tudo que pode rodar;
#   - sem colisão de nomes: os instaladores entram como texto, não
#     como código concatenado, e cada um mantém o seu `main`, o seu
#     PA_VERSAO e o seu PA_FERRAMENTA;
#   - o $0 do instalador fica certo, porque ele roda de um arquivo
#     com o nome real em vez de um temporário;
#   - a pessoa fica com os scripts no disco, para reler e reusar.
#
# O preço é o tamanho. Como `less` num arquivo destes é pesado, o
# cabeçalho impresso na tela diz em que linha cada instalador
# começa, e `--extrair` grava os dois em arquivos separados para
# quem preferir auditar um por um.
# ============================================================

# ------------------------------------------------------------
# Versão
#
# PA_VERSAO_BASE e PA_VERSAO_MAUTIC7 são substituídas pelo
# build.sh, do mesmo jeito que PA_BUILD. O menu não decide versão
# de ninguém: ele só reporta a de quem carrega dentro.
# ------------------------------------------------------------

PA_VERSAO="0.1.0"
PA_BUILD="desenvolvimento"
PA_FONTE="https://github.com/play-ahead/playahead-installer"
PA_FERRAMENTA="Menu de instaladores"

PA_VERSAO_BASE="desenvolvimento"
PA_VERSAO_MAUTIC7="desenvolvimento"

# ------------------------------------------------------------
# Catálogo
#
# Uma entrada por instalador: número, nome de arquivo, descrição e
# a função que o build.sh embutiu. Acrescentar o terceiro
# instalador é acrescentar uma linha aqui e uma no build.sh.
# ------------------------------------------------------------

PA_MENU_ARQUIVO=(base.sh mautic7.sh)
PA_MENU_NOME=(
	"Base — Docker, Traefik e Portainer"
	"Mautic 7"
)
PA_MENU_EXTRATOR=(menu_conteudo_base menu_conteudo_mautic7)
PA_MENU_MARCADOR=(
	"# ===== INSTALADOR base.sh ====="
	"# ===== INSTALADOR mautic7.sh ====="
)

# ------------------------------------------------------------
# Ajuda e versão
# ------------------------------------------------------------

main_versao() {
	printf 'Play Ahead Installer - %s\n' "$PA_FERRAMENTA"
	printf 'Versão: %s\n' "$PA_VERSAO"
	printf 'Build:  %s\n' "$PA_BUILD"
	printf 'Fonte:  %s\n' "$PA_FONTE"
	printf '\n'
	printf 'Instaladores embutidos:\n'
	printf '  base.sh      %s\n' "$PA_VERSAO_BASE"
	printf '  mautic7.sh   %s\n' "$PA_VERSAO_MAUTIC7"
}

main_ajuda() {
	cat <<'AJUDA'
Play Ahead Installer - Menu

Lista os instaladores da Play Ahead e roda o que você escolher. Os
instaladores vêm dentro deste arquivo: nada é baixado na hora.

USO
    sudo bash playahead.sh

OPÇÕES
    --extrair     grava os instaladores em arquivos separados e sai,
                  sem instalar nada
    --help        mostra esta ajuda
    --version     mostra a versão do menu e dos embutidos

Cada instalador também tem URL própria, para quem chega por um
vídeo específico:

    https://get.playahead.com.br/base
    https://get.playahead.com.br/mautic7

DOCUMENTAÇÃO
    https://github.com/play-ahead/playahead-installer
AJUDA
}

# ------------------------------------------------------------
# Onde auditar
# ------------------------------------------------------------

# menu_linha_de <marcador>
#
# Em que linha deste arquivo o instalador começa.
#
# Lê o próprio arquivo em vez de usar um número gravado no build:
# o número sai do arquivo que a pessoa tem na mão, e não de uma
# promessa feita em outra máquina. Rodando por um cano, sem arquivo
# nenhum, devolve vazio em vez de quebrar.
#
# O -x é o que faz a conta certa. Sem ele, o grep casa primeiro com
# a declaração do catálogo aqui em cima, que contém o mesmo texto
# entre aspas, e o número sai errado por alguns milhares de linhas.
menu_linha_de() {
	local marcador="$1"

	[[ -f "$0" ]] || return 0

	grep -n -F -x -m1 -- "$marcador" "$0" 2>/dev/null | cut -d: -f1
}

# menu_onde_auditar
#
# O arquivo é grande, e um `less` nele é pesado. Dizer em que linha
# cada instalador começa transforma "leia 6.700 linhas" em "pule
# para a linha 180".
menu_onde_auditar() {
	local total=""
	[[ -f "$0" ]] && total="$(wc -l <"$0" | tr -d '[:space:]')"

	ui_info "Este arquivo contém os dois instaladores. Nada é baixado."
	[[ -n "$total" ]] && ui_detalhe "São ${total} linhas no total."
	ui_vazio
	ui_info "Para auditar, os instaladores começam em:"

	local i linha
	for i in "${!PA_MENU_ARQUIVO[@]}"; do
		linha="$(menu_linha_de "${PA_MENU_MARCADOR[i]}")"

		if [[ -n "$linha" ]]; then
			ui_detalhe "$(printf '%-12s linha %s' \
				"${PA_MENU_ARQUIVO[i]}" "$linha")"
		else
			ui_detalhe "$(printf '%-12s linha não localizada' \
				"${PA_MENU_ARQUIVO[i]}")"
		fi
	done

	ui_vazio
	ui_info "No less, digite dois-pontos, o número e Enter para pular."
}

# ------------------------------------------------------------
# Gravação e execução
# ------------------------------------------------------------

# menu_gravar <indice>
#
# Grava o instalador no diretório atual, com o nome real.
#
# Nome real e não arquivo temporário por dois motivos: o $0 do
# instalador aparece certo nas mensagens de "rode de novo assim", e
# a pessoa fica com o script no disco para reler e reexecutar.
menu_gravar() {
	local i="$1"
	local arquivo="${PA_MENU_ARQUIVO[i]}"
	local extrator="${PA_MENU_EXTRATOR[i]}"

	if ! declare -F "$extrator" >/dev/null; then
		ui_fatal \
			"O instalador ${arquivo} não está embutido neste arquivo." \
			"Sinal de build quebrado. Baixe o menu de novo, ou use a" \
			"URL própria do instalador:" \
			"" \
			"    https://get.playahead.com.br/${arquivo%.sh}"
	fi

	if [[ -e "$arquivo" ]]; then
		ui_aviso "${arquivo} já existe neste diretório."

		if ! ui_confirmar "Sobrescrever?" 1; then
			ui_info "Mantido como está. Rodando o que já estava aqui."
			return 0
		fi
	fi

	if ! "$extrator" >"$arquivo"; then
		ui_fatal \
			"Não consegui gravar ${arquivo} neste diretório." \
			"Verifique a permissão de escrita em: $(pwd)"
	fi

	chmod +x "$arquivo"
	ui_ok "${arquivo} gravado em $(pwd)"
}

# menu_executar <indice>
#
# Passa o terminal para o instalador e não volta.
#
# `exec` de propósito: o instalador vira dono da sessão, o código
# de saída dele é o do menu, e não existe estado de "voltei ao
# menu depois de instalar" para ninguém raciocinar sobre. Uma
# ferramenta por vez, como decidido.
menu_executar() {
	local i="$1"
	local arquivo="${PA_MENU_ARQUIVO[i]}"

	ui_vazio
	ui_info "Rodando: bash ./${arquivo}"
	ui_separador
	ui_vazio

	exec bash "./${arquivo}"
}

# ------------------------------------------------------------
# Menu
# ------------------------------------------------------------

menu_listar() {
	ui_secao "Instaladores da Play Ahead"

	local i
	for i in "${!PA_MENU_NOME[@]}"; do
		ui_linha "  ${PA_COR_DESTAQUE}$((i + 1))${PA_COR_RESET}  ${PA_MENU_NOME[i]}"
	done

	ui_vazio
	ui_linha "  ${PA_COR_DESTAQUE}0${PA_COR_RESET}  Sair"
	ui_vazio
	ui_info "A base roda uma vez por VPS. As ferramentas vêm depois."
	ui_detalhe "Para só gravar os dois e ler antes: --extrair"
	ui_vazio
}

# menu_escolher <var_destino>
#
# Lista numerada e escolha por número, uma por vez. Sem seleção
# múltipla e sem "instalar tudo": cada instalador é dono da própria
# conversa, e juntar duas numa só traz de volta o problema que a
# separação da base resolveu.
#
# Devolve por nameref, e não pelo stdout, pelo mesmo motivo de
# ui_perguntar: dentro de $( ) o prompt seria capturado junto com a
# resposta, e o ui_fatal encerraria só o subshell.
menu_escolher() {
	local -n _escolhido="$1"

	if ! ui_interativo; then
		ui_fatal \
			"O menu precisa de um terminal para perguntar." \
			"Sem terminal, use o instalador direto:" \
			"" \
			"    sudo bash base.sh" \
			"    sudo bash mautic7.sh" \
			"" \
			"Rode com --extrair para gravar os dois aqui."
	fi

	local total="${#PA_MENU_NOME[@]}"
	local resposta

	while true; do
		printf '  Número da opção: '
		IFS= read -r resposta || resposta=""

		if [[ "$resposta" == "0" ]]; then
			ui_vazio
			ui_info "Nada foi alterado nesta máquina."
			ui_vazio
			exit 0
		fi

		if [[ "$resposta" =~ ^[0-9]+$ ]] &&
			[[ "$resposta" -ge 1 ]] &&
			[[ "$resposta" -le "$total" ]]; then

			_escolhido="$((resposta - 1))"
			return 0
		fi

		ui_aviso "Escolha um número entre 0 e ${total}."
	done
}

# ------------------------------------------------------------
# Extração sem instalar
# ------------------------------------------------------------

menu_extrair_todos() {
	ui_secao "Gravando os instaladores"

	local i
	for i in "${!PA_MENU_ARQUIVO[@]}"; do
		menu_gravar "$i"
	done

	ui_vazio
	ui_info "Leia os dois antes de rodar:"
	ui_vazio
	ui_linha "    less base.sh"
	ui_linha "    sudo bash base.sh"
	ui_vazio
	ui_linha "    less mautic7.sh"
	ui_linha "    sudo bash mautic7.sh"
	ui_vazio
}

# ------------------------------------------------------------
# main
# ------------------------------------------------------------

main() {
	local modo="menu"
	local arg

	for arg in "$@"; do
		case "$arg" in
			--extrair) modo="extrair" ;;
			--help | -h)
				main_ajuda
				exit 0
				;;
			--version | -V)
				main_versao
				exit 0
				;;
			*)
				printf 'Opção desconhecida: %s\n\n' "$arg" >&2
				main_ajuda >&2
				exit 1
				;;
		esac
	done

	ui_init 0
	ui_cabecalho

	menu_onde_auditar

	if [[ "$modo" == "extrair" ]]; then
		menu_extrair_todos
		exit 0
	fi

	menu_listar

	local escolhido=""
	menu_escolher escolhido

	menu_gravar "$escolhido"
	menu_executar "$escolhido"
}
