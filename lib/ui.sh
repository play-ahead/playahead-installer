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

# Modo do terminal, guardado pelo ui_init e devolvido no EXIT.
PA_TERMINAL_MODO=""

# Largura dos blocos e separadores.
PA_LARGURA=64

# Coluna onde os valores do resumo começam, em caracteres.
PA_RESUMO_COLUNA=20

# ------------------------------------------------------------
# Inicialização
# ------------------------------------------------------------

# ui_init [nao_interativo]
#
# Liga cores quando a saída é um terminal, respeitando a
# convenção NO_COLOR (https://no-color.org).
#
# O modo interativo cai sozinho quando stdin não é terminal.
# Sem isso, um `curl | bash` (que o tutorial desaconselha mas
# que alguém vai tentar) leria EOF em cada pergunta e adotaria
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

	# Guarda o modo do terminal e promete devolve-lo.
	#
	# O ui_descartar_entrada troca o modo por alguns
	# milissegundos e devolve em seguida. O trap cobre a morte
	# dentro dessa janela: um Ctrl-C ali deixaria o terminal sem
	# edicao de linha depois de o script sair, e a pessoa nao
	# teria como saber por que o Backspace parou de funcionar.
	if ui_interativo; then
		PA_TERMINAL_MODO="$(stty -g 2>/dev/null || true)"
		[[ -n "$PA_TERMINAL_MODO" ]] &&
			trap ui_restaurar_terminal EXIT
	fi
}

# ui_restaurar_terminal
#
# Devolve o modo salvo pelo ui_init. Roda no EXIT, e por isso
# nao imprime nada: no caminho de erro a mensagem util ja foi
# impressa pelo ui_fatal, e ruido depois dela atrapalha.
ui_restaurar_terminal() {
	[[ -n "${PA_TERMINAL_MODO:-}" ]] || return 0
	stty "$PA_TERMINAL_MODO" 2>/dev/null || true
	return 0
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
# Resumo
# ------------------------------------------------------------

# ui_largura <texto>
#
# Largura de exibição em caracteres.
#
# Nem `${#texto}` nem o `%-16s` do printf servem: os dois contam
# bytes quando o locale não é UTF-8, e daí todo rótulo acentuado
# desloca a coluna. Em vez de depender do locale da máquina, conta
# removendo os bytes de continuação do UTF-8, os que começam com
# 10xxxxxx, na faixa 0x80 a 0xBF.
ui_largura() {
	LC_ALL=C printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c
}

# ui_resumo <titulo> [<rotulo> <valor> <origem>]...
#
# A tela de confirmacao antes de comecar. Existe por dois
# motivos, e os dois sao de gente, nao de codigo: pegar dominio
# digitado errado antes de o Let's Encrypt falhar, e dar um
# momento de narrar, no video, o que vai acontecer.
#
# A <origem> de cada linha e uma destas tres:
#
#   informado   veio da pessoa, digitado ou por flag
#   detectado   lido desta maquina
#   padrao      valor que o script traz de fabrica
#
# So o "informado" recebe marca na tela, e a razao vem do teste
# de 2026-09-30: o resumo mostrou um e-mail errado, fruto de
# colagem, e passou batido no meio de dez linhas todas com o
# mesmo peso visual. Detectado e padrao a pessoa nao tem como
# conferir; informado e o unico grupo em que ela e a fonte, e
# portanto o unico em que ela pode achar o erro.
#
# A marca e um caractere, e nao so cor, porque cor nao existe com
# NO_COLOR nem quando a saida vai para arquivo.
ui_resumo() {
	local titulo="$1"
	shift

	ui_secao "$titulo"

	local rotulo valor origem preenchimento marca cor reset
	local tem_informado=0

	while [[ "$#" -ge 3 ]]; do
		rotulo="$1"
		valor="$2"
		origem="$3"
		shift 3

		preenchimento=$((PA_RESUMO_COLUNA - $(ui_largura "$rotulo")))
		[[ "$preenchimento" -lt 1 ]] && preenchimento=1

		if [[ "$origem" == "informado" ]]; then
			marca="> "
			cor="$PA_COR_DESTAQUE"
			reset="$PA_COR_RESET"
			tem_informado=1
		else
			marca="  "
			cor=""
			reset=""
		fi

		printf '  %s%s%*s%s%s%s\n' \
			"$marca" "$rotulo" "$preenchimento" "" \
			"$cor" "$valor" "$reset"
	done

	# Sobra de argumento e erro de programacao, nao de quem roda:
	# alguem passou um par onde o formato pede trio. Falhar alto
	# aqui e melhor que imprimir um resumo incompleto na tela em
	# que a pessoa vai confiar para decidir.
	if [[ "$#" -ne 0 ]]; then
		ui_fatal "ui_resumo recebeu $# argumento(s) sobrando (erro interno)."
	fi

	if [[ "$tem_informado" -eq 1 ]]; then
		ui_vazio
		ui_detalhe "> veio de você. Confira estes com atenção."
	fi

	ui_vazio
}

# ui_confirmar_resumo
#
# Pergunta se pode começar, depois do resumo.
#
# O resumo é impresso sempre, inclusive com --yes: ele vale como
# registro do que foi decidido naquela execução. A pergunta é que
# não aparece no modo automático.
ui_confirmar_resumo() {
	ui_interativo || return 0

	if ui_confirmar "Posso começar?" 1; then
		return 0
	fi

	ui_vazio
	ui_info "Nada foi alterado nesta máquina."
	ui_vazio
	exit 0
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
# tivesse acontecido. É por isso que ui_perguntar devolve o
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

# ui_descartar_entrada
#
# Joga fora o que estiver esperando no stdin.
#
# Existe por causa de colagem. No teste de 2026-09-30 a pessoa
# colou texto numa pergunta, a quebra de linha do comeco da
# colagem foi lida como resposta vazia, e a sobra ficou na fila
# do terminal esperando a proxima leitura. Resultado: a resposta
# seguinte nasceu grudada na sobra, e o e-mail do admin foi
# gravado como o dominio mais o e-mail, numa string so.
#
# Descartar antes de cada pergunta e a unica defesa que funciona
# aqui, porque quem digita nao ve o que ficou na fila. O custo e
# que colar as varias respostas de uma vez deixa de funcionar, e
# esse custo e desejado: era exatamente o que produzia a resposta
# errada em silencio.
#
# Precisa passar o terminal para modo nao canonico, e isso nao e
# preciosismo: foi medido. Em modo canonico, que e o normal, a
# linha so fica disponivel para leitura depois do Enter. Uma
# sobra de colagem sem Enter no fim fica parada no buffer do
# terminal, onde `read -t 0` nao a ve, e o descarte nao descarta
# nada. Testado num pty: com `read -t 0` sozinho, a sobra
# "testemautic.colado.com" continuou grudando na resposta
# seguinte, exatamente como no teste de 2026-09-30.
#
# Com -icanon cada caractere fica disponivel na hora, e a sobra
# parcial aparece para o descarte.
#
# O echo fica ligado de proposito. Se o script morrer entre o
# stty de ida e o de volta, um terminal sem icanon ainda mostra o
# que a pessoa digita; sem echo ela digitaria no escuro. O
# ui_init tambem registra um trap de EXIT que devolve o modo
# original, para o caso de a morte acontecer aqui dentro.
#
# O contador existe para o laco nunca ser infinito.
ui_descartar_entrada() {
	ui_interativo || return 0

	local modo
	modo="$(stty -g 2>/dev/null)" || return 0

	stty -icanon min 0 time 0 2>/dev/null || {
		stty "$modo" 2>/dev/null
		return 0
	}

	local voltas=0

	# Sem nome de variavel: o que for lido cai em REPLY e morre
	# ali. Nomear uma variavel so para descartar renderia um
	# aviso de valor nao usado, com razao. (E comentario nao pode
	# comecar com a palavra shellcheck: vira diretiva e quebra o
	# build.)
	while [[ "$voltas" -lt 200 ]] && read -r -t 0 2>/dev/null; do
		read -r -n 4096 -t 0.2 2>/dev/null
		voltas=$((voltas + 1))
	done

	stty "$modo" 2>/dev/null
	return 0
}

# ui_limpar_resposta <var>
#
# Tira da resposta o que nao e conteudo: retorno de carro, que
# vem em toda colagem feita a partir do Windows, tabulacao, e
# espaco nas duas pontas.
#
# Um dominio colado com retorno de carro no fim carrega o
# caractere invisivel junto. Ele passa pelo validador, porque nem
# todo locale o considera espaco, e chega ao label do Traefik. O
# roteador sobe com um Host que nunca casa, e o dominio devolve
# 404 sem nada no log.
ui_limpar_resposta() {
	local -n _bruta="$1"

	_bruta="${_bruta//$'\r'/}"
	_bruta="${_bruta//$'\t'/}"
	_bruta="${_bruta//$'\n'/}"

	# Espaco das duas pontas, sem sed e sem subshell.
	_bruta="${_bruta#"${_bruta%%[![:space:]]*}"}"
	_bruta="${_bruta%"${_bruta##*[![:space:]]}"}"
}

# ui_perguntar <var_destino> <texto> [padrao] [funcao_validadora]
#
# A validadora recebe a resposta e devolve 0 quando aceita. Ela
# mesma explica o problema na tela; aqui só repetimos a pergunta.
#
# Sem interação: adota o padrão. Não havendo padrão, é dado que
# falta, e o script para: o comportamento prometido para --yes.
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
		ui_descartar_entrada
		printf '  %s: ' "$rotulo"
		IFS= read -r resposta || resposta=""
		ui_limpar_resposta resposta

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

# ui_perguntar_opcional <var_destino> <texto> [funcao_validadora]
#
# Como ui_perguntar, mas Enter tambem e resposta: devolve 1 e
# deixa a variavel vazia. Serve para dado que o script sabe
# dispensar, como o subdominio do Portainer.
#
# Nao trata o modo automatico, de proposito. La o vazio nao seria
# escolha de ninguem, e deixar esta funcao decidir espalharia a
# regra do --yes por dentro do ui.sh. Quem chama confere
# ui_interativo antes e diz, com o nome da flag na tela, o que
# falta.
ui_perguntar_opcional() {
	local -n _destino_opcional="$1"
	local texto="$2"
	local validadora="${3:-}"

	local resposta
	while true; do
		ui_descartar_entrada
		printf '  %s %s[Enter pula]%s: ' \
			"$texto" "$PA_COR_FRACA" "$PA_COR_RESET"
		IFS= read -r resposta || resposta=""
		ui_limpar_resposta resposta

		if [[ -z "$resposta" ]]; then
			_destino_opcional=""
			return 1
		fi

		if [[ -n "$validadora" ]] && ! "$validadora" "$resposta"; then
			continue
		fi

		_destino_opcional="$resposta"
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
		ui_descartar_entrada
		printf '  %s %s[%s]%s: ' \
			"$texto" "$PA_COR_FRACA" "$dica" "$PA_COR_RESET"
		IFS= read -r resposta || resposta=""
		ui_limpar_resposta resposta

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
# ou mais de uma rede candidata: casos em que chutar dá 404
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
		ui_descartar_entrada
		printf '  Número da opção %s[1]%s: ' \
			"$PA_COR_FRACA" "$PA_COR_RESET"
		IFS= read -r resposta || resposta=""
		ui_limpar_resposta resposta
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
