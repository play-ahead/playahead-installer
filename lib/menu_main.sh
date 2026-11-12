#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/menu_main.sh
# Menu: a porta de entrada. Lista os instaladores da Play Ahead e
# chama o escolhido.
#
# Depende de lib/ui.sh e das funções que o build.sh embute.
#
# O MENU CONTÉM OS INSTALADORES, não os busca.
#
# Essa é a decisão que faz o menu conviver com a regra de que um
# instalador não baixa nem executa outro. O build.sh embute cada
# instalador publicado aqui dentro, como heredoc citado, mesmo
# mecanismo já validado para o template do compose.
# Escolhido o número, o menu grava o instalador no diretório atual,
# roda, e volta para a lista quando ele termina.
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
# começa, e `--extrair` grava todos em arquivos separados para
# quem preferir auditar um por um.
#
# A lista não mora neste arquivo. Quem a escreve é o build.sh, com
# uma chamada a menu_registrar para cada instalador que ele embute:
# entrou um instalador novo no build, ele aparece na lista.
# ============================================================

# ------------------------------------------------------------
# Versão
#
# O menu não decide versão de ninguém: ele só reporta a de quem
# carrega dentro, que chega pelo menu_registrar.
# ------------------------------------------------------------

PA_VERSAO="0.1.0"
PA_BUILD="desenvolvimento"
PA_FONTE="https://github.com/play-ahead/playahead-installer"
PA_FERRAMENTA="Menu de instaladores"

# O que o cabeçalho de tela diz embaixo do logo. Nos instaladores é o
# nome da ferramenta; aqui é o nome do conjunto, porque o menu é a
# entrada para todas elas.
PA_TITULO="Play Ahead Installer"

# ------------------------------------------------------------
# Catálogo
#
# Uma posição por instalador embutido, na ordem em que o build.sh os
# registrou. Vazio no código-fonte: sem build não há instalador
# nenhum aqui dentro.
# ------------------------------------------------------------

PA_MENU_ARQUIVO=()
PA_MENU_VERSAO=()
PA_MENU_NOME=()
PA_MENU_DESCRICAO=()
PA_MENU_INSTALADO=()
PA_MENU_EXTRATOR=()
PA_MENU_MARCADOR=()

# O grupo de cada instalador (infraestrutura, marketing, atendimento).
# Ainda não aparece na tela: com duas ferramentas, título de grupo
# seria mais linha que conteúdo. Fica guardado para o dia em que a
# lista crescer, e aí o menu_listar passa a imprimir o nome do grupo
# antes do primeiro item de cada um. Ver "O menu", no CLAUDE.md.
# shellcheck disable=SC2034
PA_MENU_GRUPO=()

# menu_registrar <arquivo> <versão> <nome> <descrição> <grupo> <marca de instalado>
#
# Põe um instalador na lista. Quem chama é o trecho que o build.sh
# gera, logo depois de embutir cada instalador.
#
# A <marca de instalado> é um arquivo que só existe nesta máquina
# depois de aquele instalador ter terminado, ou mais de um, separados
# por espaço. O menu olha se o arquivo existe, e mais nada: detectar
# de verdade é trabalho do instalador, quando roda.
menu_registrar() {
	local arquivo="$1"

	PA_MENU_ARQUIVO+=("$arquivo")
	PA_MENU_VERSAO+=("$2")
	PA_MENU_NOME+=("$3")
	PA_MENU_DESCRICAO+=("$4")
	PA_MENU_GRUPO+=("$5")
	PA_MENU_INSTALADO+=("$6")
	PA_MENU_EXTRATOR+=("menu_conteudo_${arquivo%.sh}")
	PA_MENU_MARCADOR+=("# ===== INSTALADOR ${arquivo} =====")
}

# menu_instalado <indice>
#
# Verdadeiro quando a marca daquele instalador existe nesta máquina.
menu_instalado() {
	local marcas=() marca

	# Pode ser mais de um caminho, separados por espaço, e basta um
	# deles existir. O read separa as palavras sem expandir curinga,
	# o que um "for" sem aspas faria.
	read -ra marcas <<<"${PA_MENU_INSTALADO[$1]}"

	for marca in ${marcas[@]+"${marcas[@]}"}; do
		[[ -e "$marca" ]] && return 0
	done

	return 1
}

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

	local i
	for i in "${!PA_MENU_ARQUIVO[@]}"; do
		printf '  %-12s %s\n' "${PA_MENU_ARQUIVO[i]}" "${PA_MENU_VERSAO[i]}"
	done
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

AJUDA

	local i
	for i in "${!PA_MENU_ARQUIVO[@]}"; do
		printf '    https://get.playahead.com.br/%s\n' "${PA_MENU_ARQUIVO[i]%.sh}"
	done

	cat <<'AJUDA'

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
# O -x é o que faz a conta certa: só serve a linha que é o marcador
# inteiro, e não uma linha qualquer que o cite.
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

	ui_info "Os instaladores vêm dentro deste arquivo. Nada é baixado."
	[[ -n "$total" ]] && ui_detalhe "São ${total} linhas no total."
	ui_vazio
	ui_info "Para ler antes de rodar, cada um começa em:"

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

	# Arquivo já na pasta: comparar antes de perguntar.
	#
	# Perguntar sempre tinha um efeito ruim e silencioso. Quem
	# respondia "não" mandava o menu rodar uma cópia que podia ser
	# de outra versão, e o menu não tinha como saber nem avisar. O
	# resultado seria um instalador antigo rodando enquanto a tela
	# anunciou a versão do menu.
	#
	# Comparar resolve os dois casos sem pergunta desnecessária:
	# igual ao embutido, não há o que decidir; diferente, é
	# informação que muda a resposta e precisa aparecer.
	#
	# A comparação é byte a byte. Comparar versão declarada no
	# cabeçalho não serviria: uma cópia editada à mão mantém o
	# número e muda o código.
	# Link simbólico com o nome do instalador: para. Gravar por cima
	# seguiria o link e sobrescreveria, como root, o arquivo para onde
	# ele aponta. Medido em 2026-11-11, numa pasta de teste: o arquivo
	# apontado virou o base.sh. Em pasta compartilhada como /tmp,
	# qualquer usuário da máquina consegue deixar um link desses.
	if [[ -L "$arquivo" ]]; then
		ui_fatal \
			"${arquivo} nesta pasta é um link simbólico, e não um arquivo." \
			"Gravar por cima sobrescreveria o arquivo para onde ele aponta:" \
			"" \
			"    $(readlink -- "$arquivo")" \
			"" \
			"Apague o link, ou rode o menu de outra pasta."
	fi

	# Mesmo igual ao embutido, o arquivo é gravado de novo, sem
	# pergunta. Entre a comparação e a execução, quem fosse dono dele
	# numa pasta compartilhada poderia trocá-lo. Gravado agora, por
	# troca de nome, ele é de root e é o que este menu carrega.
	local igual=0

	if [[ -e "$arquivo" ]]; then
		if "$extrator" | cmp -s - "$arquivo"; then
			igual=1
		fi
	fi

	if [[ -e "$arquivo" && "$igual" -eq 0 ]]; then
		# A mensagem precisa dizer que o que existe é o ARQUIVO do
		# instalador, e não a ferramenta instalada. No teste de
		# 2026-09-30 a versão anterior, "mautic7.sh já existe neste
		# diretório", foi lida como "o Mautic já está instalado", e
		# é uma leitura razoável: quem está no meio de uma
		# instalação pensa na ferramenta, não em arquivo.
		ui_aviso "O arquivo ${arquivo} já está nesta pasta, e é DIFERENTE"
		ui_aviso "da cópia que vem dentro deste menu."
		ui_detalhe "É o instalador em si, gravado ou baixado antes."
		ui_detalhe "Isso não diz nada sobre a ferramenta estar"
		ui_detalhe "instalada nesta máquina: quem verifica isso é o"
		ui_detalhe "próprio instalador, quando rodar."
		ui_vazio
		ui_detalhe "Pode ser de outra versão, ou ter sido editado."
		ui_detalhe "Substituir é o padrão, porque é o único conteúdo"
		ui_detalhe "que este menu conhece e acabou de anunciar."

		if ! ui_confirmar "Substituir pela cópia que vem neste menu?" 1; then
			ui_aviso "Arquivo mantido. Vou rodar o que já estava aqui,"
			ui_aviso "que não é o que este menu carrega."
			return 0
		fi
	fi

	# Grava num arquivo novo, de nome que ninguém adivinha, e só
	# então troca pelo nome final. A troca substitui a entrada da
	# pasta em vez de escrever dentro do que estiver lá, e quem roda o
	# instalador em seguida nunca pega um arquivo pela metade.
	local novo
	if ! novo="$(mktemp "./${arquivo}.XXXXXXXX")" ||
		! "$extrator" >"$novo" ||
		! chmod 755 "$novo" ||
		! mv -f -- "$novo" "$arquivo"; then
		rm -f -- "${novo:-}"
		ui_fatal \
			"Não consegui gravar ${arquivo} neste diretório." \
			"Verifique a permissão de escrita em: $(pwd)"
	fi

	if [[ "$igual" -eq 1 ]]; then
		ui_ok "${arquivo} já estava aqui, igual ao deste menu"
	else
		ui_ok "${arquivo} gravado em $(pwd)"
	fi
}

# menu_executar <indice>
#
# Roda o instalador como processo filho e volta.
#
# Até 2026-10-06 era `exec`: o instalador virava dono da sessão e
# o menu sumia. Depois de instalar a base a pessoa tinha de rodar
# o menu de novo para chegar no Mautic, que é o passo seguinte de
# todo mundo. Agora o menu espera o instalador terminar e mostra
# a lista outra vez.
#
# Continua sendo uma ferramenta por vez, e cada instalador
# continua dono da própria conversa: ele roda num bash próprio,
# com o seu main, as suas variáveis e o seu exit. O menu não lê
# nada do que ele fez, só o código de saída.
#
# PA_PELO_MENU=1 vai no ambiente do filho para ele trocar duas
# mensagens que mandariam baixar por `curl` um instalador que o
# menu já tem. Rodando o instalador direto, a variável não existe
# e nada muda.
#
# Ctrl-C: o menu instala um tratador vazio enquanto o filho roda.
# Tratador, e não `trap '' INT`: sinal IGNORADO é herdado pelo
# filho, e o bash não deixa um script desfazer isso, então o
# Ctrl-C pararia de funcionar dentro do instalador. Com tratador,
# o filho recebe o sinal normalmente e morre, e o menu sobrevive
# para mostrar a lista.
menu_executar() {
	local i="$1"
	local arquivo="${PA_MENU_ARQUIVO[i]}"

	ui_vazio
	ui_info "Rodando: bash ./${arquivo}"
	ui_separador
	ui_vazio

	local codigo=0
	trap ':' INT
	PA_PELO_MENU=1 bash "./${arquivo}" || codigo="$?"
	trap - INT

	ui_vazio
	ui_separador

	case "$codigo" in
		0)
			ui_ok "${arquivo} terminou."
			;;
		130)
			ui_aviso "${arquivo} foi interrompido (Ctrl-C)."
			ui_detalhe "O que já tinha sido feito continua feito; o instalador"
			ui_detalhe "não desfaz nada. Rodar de novo retoma de onde dá."
			;;
		*)
			ui_aviso "${arquivo} terminou com erro (código ${codigo})."
			ui_detalhe "A explicação está logo acima, na saída dele."
			;;
	esac
}

# ------------------------------------------------------------
# Menu
# ------------------------------------------------------------

# menu_listar
#
# A lista sai do catálogo, na ordem em que os instaladores foram
# registrados. "instalado" aparece ao lado do que já existe nesta
# máquina, olhando só a marca de cada um (ver menu_registrar).
#
# Quando a lista crescer, os itens passam a vir agrupados: o nome do
# grupo numa linha, e embaixo os instaladores dele, com a numeração
# seguindo de um grupo para o outro. O grupo de cada instalador já
# está em PA_MENU_GRUPO.
menu_listar() {
	local itens=()
	local i estado

	for i in "${!PA_MENU_NOME[@]}"; do
		estado=""
		menu_instalado "$i" && estado="instalado"

		itens+=("$((i + 1))" "${PA_MENU_NOME[i]}" "$estado" "${PA_MENU_DESCRICAO[i]}")
	done
	itens+=("0" "Sair" "" "")

	ui_lista "Instaladores" "${itens[@]}"
	ui_detalhe "Para só gravar os instaladores e ler antes: --extrair"
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
			"Sem terminal, use cada instalador direto. Para gravar" \
			"todos nesta pasta, sem instalar nada:" \
			"" \
			"    bash ${0} --extrair"
	fi

	local total="${#PA_MENU_NOME[@]}"
	local resposta

	while true; do
		# Mesma higiene das perguntas dos instaladores. Aqui ela
		# importa ainda mais: o menu reaparece logo depois de um
		# instalador terminar, e qualquer Enter apertado durante a
		# instalação estaria esperando na fila.
		ui_descartar_entrada
		printf '%sNúmero da opção: ' "$PA_UI_M_ITEM"
		IFS= read -r resposta || resposta=""
		ui_limpar_resposta resposta

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
	ui_info "Leia cada um antes de rodar:"

	for i in "${!PA_MENU_ARQUIVO[@]}"; do
		ui_vazio
		ui_comando "less ${PA_MENU_ARQUIVO[i]}"
		ui_comando "sudo bash ${PA_MENU_ARQUIVO[i]}"
	done
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

	# Volta para a lista depois de cada instalador. Sai só pelo 0,
	# que o menu_escolher trata, ou por Ctrl-C fora de instalador.
	local escolhido
	while true; do
		menu_listar

		escolhido=""
		menu_escolher escolhido

		menu_gravar "$escolhido"
		menu_executar "$escolhido"
	done
}
