#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/ui.sh
# Cores, mensagens, perguntas e esperas.
#
# Esta é uma biblioteca: carregar o arquivo não executa nada,
# só define funções. Quem liga as cores é ui_init, chamada pelo
# orquestrador depois do parse das flags.
#
# Depois do build.sh este arquivo vira um trecho do
# dist/mautic7.sh e passa a dividir o escopo global com as
# outras libs. Daí duas regras que valem para o arquivo todo:
#
#   1. Todo nome público leva prefixo ui_ ou PA_.
#   2. Nada de `return` fora de função e nada de `readonly` no
#      topo. Num arquivo concatenado isso deixa de ser código
#      de biblioteca e vira código de script, onde `return`
#      é erro de sintaxe.
#
# Toda mensagem passa por ui_linha. Quando o log de execução
# for decidido, é o único ponto que precisa mudar.
# ============================================================

# ------------------------------------------------------------
# Estado
# ------------------------------------------------------------

# Preenchidas por ui_init. Vazias por padrão para que o arquivo
# funcione mesmo se alguém esquecer de inicializar.
PA_COR_RESET=""
PA_COR_TITULO=""
PA_COR_OK=""
PA_COR_AVISO=""
PA_COR_ERRO=""
PA_COR_FRACA=""
PA_COR_DESTAQUE=""

# 1 quando dá para perguntar: --yes ausente e stdin é terminal.
PA_INTERATIVO=0

# Largura dos blocos e separadores.
PA_LARGURA=64

# ------------------------------------------------------------
# Inicialização
# ------------------------------------------------------------

# ui_init [nao_interativo]
#
# Liga cores quando a saída é um terminal, respeitando a
# convenção NO_COLOR (https://no-color.org).
#
# O modo interativo cai sozinho quando stdin não é terminal.
# Sem isso, um `curl | bash` — que o tutorial desaconselha mas
# que alguém vai tentar — leria EOF em cada pergunta e adotaria
# todos os defaults em silêncio.
ui_init() {
	local nao_interativo="${1:-0}"

	if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
		PA_COR_RESET=$'\033[0m'
		PA_COR_TITULO=$'\033[1;36m'
		PA_COR_OK=$'\033[0;32m'
		PA_COR_AVISO=$'\033[0;33m'
		PA_COR_ERRO=$'\033[1;31m'
		PA_COR_FRACA=$'\033[0;90m'
		PA_COR_DESTAQUE=$'\033[1m'
	fi

	if [[ "$nao_interativo" == "1" ]]; then
		PA_INTERATIVO=0
	elif [[ -t 0 ]]; then
		PA_INTERATIVO=1
	else
		PA_INTERATIVO=0
	fi
}

# ui_interativo
#
# Verdadeiro quando ainda dá para perguntar alguma coisa.
ui_interativo() {
	[[ "$PA_INTERATIVO" == "1" ]]
}

# ------------------------------------------------------------
# Primitiva de saída
# ------------------------------------------------------------

# ui_linha <texto...>
#
# Único ponto de escrita do módulo.
#
# Só erro vai para stderr. Aviso fica no stdout junto com o resto:
# ui_aviso quase sempre vem seguido de ui_detalhe explicando o
# aviso, e separar os dois fluxos faz as linhas trocarem de ordem
# assim que a saída é redirecionada para um arquivo. Descoberto
# testando a tabela de detecção do Traefik, onde o aviso aparecia
# depois dos próprios detalhes.
ui_linha() {
	printf '%s\n' "$*"
}

ui_linha_erro() {
	printf '%s\n' "$*" >&2
}

# ------------------------------------------------------------
# Mensagens
# ------------------------------------------------------------

ui_info() {
	ui_linha "  $*"
}

ui_passo() {
	ui_linha "${PA_COR_TITULO}==>${PA_COR_RESET} $*"
}

ui_ok() {
	ui_linha "  ${PA_COR_OK}✓${PA_COR_RESET} $*"
}

ui_aviso() {
	ui_linha "  ${PA_COR_AVISO}!${PA_COR_RESET} $*"
}

ui_erro() {
	ui_linha_erro "  ${PA_COR_ERRO}✗${PA_COR_RESET} $*"
}

# ui_detalhe <texto...>
#
# Informação secundária: caminho de arquivo, valor detectado,
# comando sugerido. Recuada e apagada de propósito, para não
# competir com a mensagem principal.
ui_detalhe() {
	ui_linha "    ${PA_COR_FRACA}$*${PA_COR_RESET}"
}

ui_vazio() {
	ui_linha ""
}

ui_separador() {
	local linha
	printf -v linha '%*s' "$PA_LARGURA" ''
	ui_linha "${PA_COR_FRACA}${linha// /-}${PA_COR_RESET}"
}

# ui_secao <titulo>
ui_secao() {
	ui_vazio
	ui_linha "${PA_COR_TITULO}${PA_COR_DESTAQUE}$1${PA_COR_RESET}"
	ui_separador
}

# ------------------------------------------------------------
# Falha
# ------------------------------------------------------------

# ui_fatal <mensagem> [linha_de_ajuda...]
#
# Encerra com código 1. As linhas seguintes à mensagem são
# impressas como detalhe: é onde entra o "como resolver".
#
# Nunca chamar dentro de $( ). Numa substituição de comando o
# exit encerra apenas o subshell e o script segue como se nada
# tivesse acontecido — é por isso que ui_perguntar devolve o
# valor por nameref em vez de imprimir no stdout.
ui_fatal() {
	local mensagem="$1"
	shift

	ui_vazio
	ui_erro "$mensagem"

	local ajuda
	for ajuda in "$@"; do
		ui_linha_erro "    ${PA_COR_FRACA}${ajuda}${PA_COR_RESET}"
	done

	ui_vazio
	exit 1
}

# ------------------------------------------------------------
# Cabeçalho
# ------------------------------------------------------------

# ui_cabecalho
#
# O bloco de licença e aviso exigido pelo CLAUDE.md. Imprime e
# faz uma pausa curta, sem pedir confirmação digitada: "digite
# concordo" travaria a instalação automatizada e atrapalharia a
# gravação do vídeo.
ui_cabecalho() {
	ui_vazio
	ui_linha "${PA_COR_TITULO}============================================================${PA_COR_RESET}"
	ui_linha "${PA_COR_TITULO}${PA_COR_DESTAQUE} PLAY AHEAD INSTALLER${PA_COR_RESET}"
	[[ -n "${PA_FERRAMENTA:-}" ]] &&
		ui_linha "${PA_COR_TITULO} ${PA_FERRAMENTA}${PA_COR_RESET}"
	ui_linha " https://playahead.com.br"
	ui_linha " Fabio Roger de Oliveira ME | CNPJ 31.176.090/0001-08"
	ui_vazio
	ui_linha " Versão ${PA_VERSAO:-dev} | build ${PA_BUILD:-desenvolvimento}"
	ui_linha " Licença MIT. Consulte o arquivo LICENSE."
	ui_vazio
	ui_linha "${PA_COR_AVISO} AVISO${PA_COR_RESET}"
	ui_linha " Este script altera a configuração do servidor onde é executado:"
	ui_linha " instala pacotes, cria containers, volumes e regras de rede."
	ui_linha " Execute apenas em servidor dedicado a esta finalidade e do qual"
	ui_linha " você tenha cópia de segurança."
	ui_vazio
	ui_linha " O software é fornecido \"como está\", sem garantia de qualquer"
	ui_linha " espécie. A Play Ahead não se responsabiliza por perda de dados,"
	ui_linha " indisponibilidade ou danos decorrentes do uso."
	ui_vazio
	ui_linha " Leia o código antes de executar."
	ui_linha "${PA_COR_TITULO}============================================================${PA_COR_RESET}"
	ui_vazio

	sleep 3
}

# ------------------------------------------------------------
# Perguntas
#
# Todas devolvem o valor por nameref, não pelo stdout. Assim a
# função roda no mesmo shell e ui_fatal consegue encerrar o
# script de verdade quando falta dado no modo --yes.
# ------------------------------------------------------------

# ui_perguntar <var_destino> <texto> [padrao] [funcao_validadora]
#
# A validadora recebe a resposta e devolve 0 quando aceita. Ela
# mesma explica o problema na tela; aqui só repetimos a pergunta.
#
# Sem interação: adota o padrão. Não havendo padrão, é dado que
# falta, e o script para — o comportamento prometido para --yes.
ui_perguntar() {
	local -n _destino="$1"
	local texto="$2"
	local padrao="${3:-}"
	local validadora="${4:-}"

	local rotulo="$texto"
	[[ -n "$padrao" ]] && rotulo+=" ${PA_COR_FRACA}[${padrao}]${PA_COR_RESET}"

	if ! ui_interativo; then
		if [[ -z "$padrao" ]]; then
			ui_fatal \
				"Falta um dado obrigatório: ${texto}" \
				"O modo não interativo não pergunta nada." \
				"Informe o valor por flag e rode de novo."
		fi
		_destino="$padrao"
		return 0
	fi

	local resposta
	while true; do
		printf '  %s: ' "$rotulo"
		IFS= read -r resposta || resposta=""

		[[ -z "$resposta" ]] && resposta="$padrao"

		if [[ -z "$resposta" ]]; then
			ui_aviso "Este campo é obrigatório."
			continue
		fi

		if [[ -n "$validadora" ]] && ! "$validadora" "$resposta"; then
			continue
		fi

		_destino="$resposta"
		return 0
	done
}

# ui_confirmar <texto> [padrao_sim]
#
# Devolve 0 para sim. Sem interação, adota o padrão em silêncio:
# no modo --yes ninguém está lendo a tela.
ui_confirmar() {
	local texto="$1"
	local padrao_sim="${2:-0}"

	local dica="s/N"
	[[ "$padrao_sim" == "1" ]] && dica="S/n"

	if ! ui_interativo; then
		[[ "$padrao_sim" == "1" ]]
		return $?
	fi

	local resposta
	while true; do
		printf '  %s %s[%s]%s: ' \
			"$texto" "$PA_COR_FRACA" "$dica" "$PA_COR_RESET"
		IFS= read -r resposta || resposta=""

		case "${resposta,,}" in
			s | sim | y | yes) return 0 ;;
			n | nao | não | no) return 1 ;;
			"") [[ "$padrao_sim" == "1" ]] && return 0 || return 1 ;;
			*) ui_aviso "Responda s ou n." ;;
		esac
	done
}

# ui_escolher <var_destino> <texto> <opcao...>
#
# Menu numerado. Usado quando a máquina tem mais de um Traefik
# ou mais de uma rede candidata — casos em que chutar dá 404
# silencioso, então perguntar é obrigatório.
ui_escolher() {
	local -n _escolhido="$1"
	local texto="$2"
	shift 2
	local opcoes=("$@")

	if [[ "${#opcoes[@]}" -eq 0 ]]; then
		ui_fatal "ui_escolher chamada sem opções (erro interno do instalador)."
	fi

	if [[ "${#opcoes[@]}" -eq 1 ]]; then
		_escolhido="${opcoes[0]}"
		return 0
	fi

	if ! ui_interativo; then
		ui_fatal \
			"Mais de uma opção possível para: ${texto}" \
			"Encontradas: ${opcoes[*]}" \
			"O modo não interativo não escolhe sozinho." \
			"Informe o valor por flag e rode de novo."
	fi

	ui_vazio
	ui_info "$texto"

	local i
	for i in "${!opcoes[@]}"; do
		ui_linha "    ${PA_COR_DESTAQUE}$((i + 1))${PA_COR_RESET}) ${opcoes[i]}"
	done

	local resposta
	while true; do
		printf '  Número da opção %s[1]%s: ' \
			"$PA_COR_FRACA" "$PA_COR_RESET"
		IFS= read -r resposta || resposta=""
		[[ -z "$resposta" ]] && resposta=1

		if [[ "$resposta" =~ ^[0-9]+$ ]] &&
			[[ "$resposta" -ge 1 ]] &&
			[[ "$resposta" -le "${#opcoes[@]}" ]]; then
			_escolhido="${opcoes[resposta - 1]}"
			return 0
		fi

		ui_aviso "Escolha um número entre 1 e ${#opcoes[@]}."
	done
}

# ------------------------------------------------------------
# Esperas
# ------------------------------------------------------------

# ui_aguardar_ate <descricao> <timeout_seg> <comando...>
#
# Repete o comando até ele passar ou o tempo acabar. Devolve 0
# quando passou.
#
# É a alternativa ao `sleep 120` que o CLAUDE.md proíbe: o
# script espera a condição real, diz na tela o que está
# esperando e desiste num prazo conhecido em vez de travar.
ui_aguardar_ate() {
	local descricao="$1"
	local timeout="$2"
	shift 2

	local intervalo=3
	local decorrido=0

	# Os pontinhos só existem para quem está olhando a tela.
	# Sem terminal eles viram lixo no log, então a linha de
	# progresso é suprimida e fica só o resultado.
	local animar=0
	if [[ "$PA_INTERATIVO" == "1" ]]; then
		animar=1
		printf '  %s ' "$descricao"
	fi

	while true; do
		if "$@" >/dev/null 2>&1; then
			[[ "$animar" == "1" ]] && printf '\n'
			ui_ok "${descricao}: pronto em ${decorrido}s"
			return 0
		fi

		if [[ "$decorrido" -ge "$timeout" ]]; then
			[[ "$animar" == "1" ]] && printf '\n'
			ui_erro "${descricao}: nada respondeu em ${timeout}s"
			return 1
		fi

		[[ "$animar" == "1" ]] && printf '.'
		sleep "$intervalo"
		decorrido=$((decorrido + intervalo))
	done
}

# ------------------------------------------------------------
# Segredos
# ------------------------------------------------------------

# ui_mascarar <segredo>
#
# Ecoa o valor com o miolo trocado por asteriscos. Serve para
# confirmar na tela que a senha certa foi usada sem imprimir a
# senha, e para o dia em que o log de execução existir.
ui_mascarar() {
	local segredo="$1"
	local tamanho="${#segredo}"

	if [[ "$tamanho" -le 8 ]]; then
		printf '%s\n' "********"
		return 0
	fi

	printf '%s********%s\n' "${segredo:0:3}" "${segredo: -2}"
}
