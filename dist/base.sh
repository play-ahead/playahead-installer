#!/usr/bin/env bash
# ============================================================
# PLAY AHEAD INSTALLER
# Base: Docker, Traefik e Portainer
# https://playahead.com.br
# Fabio Roger de Oliveira ME | CNPJ 31.176.090/0001-08
#
# Versão: 0.1.0
# Build:  2026-09-12T19:47:59Z
# Fonte:  https://github.com/play-ahead/playahead-installer
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
#
# ARQUIVO GERADO POR build.sh. NÃO EDITE AQUI.
# O código-fonte é modular e vive em lib/*.sh, em https://github.com/play-ahead/playahead-installer
# ============================================================

set -euo pipefail

# ============================================================
# lib/ui.sh
# ============================================================

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
# Resumo
# ------------------------------------------------------------

# ui_largura <texto>
#
# Largura de exibição em caracteres.
#
# Nem `${#texto}` nem o `%-16s` do printf servem: os dois contam
# bytes quando o locale não é UTF-8, e daí todo rótulo acentuado
# desloca a coluna. Em vez de depender do locale da máquina, conta
# removendo os bytes de continuação do UTF-8 — os que começam com
# 10xxxxxx, na faixa 0x80 a 0xBF.
ui_largura() {
	LC_ALL=C printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c
}

# ui_resumo <titulo> [<rótulo> <valor>]...
#
# A tela de confirmação antes de começar. Existe por dois motivos,
# e os dois são de gente, não de código: pegar domínio digitado
# errado antes de o Let's Encrypt falhar, e dar um momento de
# narrar, no vídeo, o que vai acontecer.
ui_resumo() {
	local titulo="$1"
	shift

	ui_secao "$titulo"

	local rotulo valor preenchimento
	while [[ "$#" -ge 2 ]]; do
		rotulo="$1"
		valor="$2"
		shift 2

		preenchimento=$((PA_RESUMO_COLUNA - $(ui_largura "$rotulo")))
		[[ "$preenchimento" -lt 1 ]] && preenchimento=1

		printf '  %s%*s%s\n' \
			"$rotulo" "$preenchimento" "" "$valor"
	done

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

# ============================================================
# lib/checks.sh
# ============================================================

# shellcheck shell=bash
#
# ============================================================
# lib/checks.sh
# Pré-checagens e validadores.
#
# Depende de lib/ui.sh.
#
# Regra do módulo: falhar cedo, com mensagem clara em português
# e dizendo como resolver. Cada falha silenciosa aqui vira
# comentário de "não funcionou" no vídeo.
#
# Este arquivo só lê e decide. Nada aqui altera a máquina.
#
# É compartilhado pelos dois instaladores, então guarda apenas o
# que os dois usam: interpretador, privilégio, arquitetura,
# sistema operacional, memória, disco, DNS e os validadores. A
# descoberta de portas em escuta mora em lib/portas.sh, porque só
# o instalador de base precisa dela.
# ============================================================

# ------------------------------------------------------------
# Constantes
# ------------------------------------------------------------

# Ubuntu suportado no lançamento. Debian 12 entra depois de
# testado: cada SO a mais é uma matriz de teste a mais.
PA_SO_SUPORTADOS=("22.04" "24.04")

# Piso de RAM em MB.
#
# Não são 2048. Uma VPS vendida como "2 GB" reporta entre 1950 e
# 2000 MB depois do que o kernel reserva, e comparar com 2048
# reprovaria justamente as máquinas que o README promete
# suportar.
PA_RAM_MINIMA_MB=1900

# Limiar do swap em MB.
#
# Abaixo disto, e sem swap ativo, o instalador cria um swapfile de
# 2 GB.
#
# Não são 4096, pelo mesmo motivo de PA_RAM_MINIMA_MB não ser 2048:
# uma VPS vendida como "4 GB" reporta 3915 MB depois do que o kernel
# reserva, medido na máquina de teste. Comparar com 4096 daria swap
# a toda máquina de 4 GB, que não precisa.
PA_RAM_SWAP_MB=3800

# Piso de disco livre em MB. Provisório: as imagens do Mautic e
# do MariaDB somam perto de 2 GB, e o resto é folga para o banco
# crescer. O CLAUDE.md marca este número como "a medir no
# primeiro teste real".
PA_DISCO_MINIMO_MB=10240

# Faixas de CDN que fazem o domínio resolver para um IP que não
# é o da VPS sem que o DNS esteja errado.
#
# A lista fica embutida de propósito. Baixar a lista oficial a
# cada execução seria mais uma dependência de rede e mais um
# terceiro consultado, contra a promessa de que o script não
# envia nada. Fonte: https://www.cloudflare.com/ips-v4
#
# Só Cloudflare por enquanto: é o que este público usa. Fastly e
# Akamai entram se aparecerem no suporte.
PA_FAIXAS_CDN=(
	"173.245.48.0/20"
	"103.21.244.0/22"
	"103.22.200.0/22"
	"103.31.4.0/22"
	"141.101.64.0/18"
	"108.162.192.0/18"
	"190.93.240.0/20"
	"188.114.96.0/20"
	"197.234.240.0/22"
	"198.41.128.0/17"
	"162.158.0.0/15"
	"104.16.0.0/13"
	"104.24.0.0/14"
	"172.64.0.0/13"
	"131.0.72.0/22"
)

# Preenchidas pelas checagens, lidas pelo resto do instalador.
PA_SO_ID=""
PA_SO_VERSAO=""
PA_IP_PUBLICO=""

# Conclusão da checagem de DNS, em texto, para a tela de resumo.
# Quem lê é o orquestrador; dizer "verificado" sem dizer o que foi
# concluído não ajudaria ninguém a conferir.
PA_DNS_RESULTADO="não verificado"

# Existe para poder apontar o parser para um arquivo de exemplo
# durante os testes. Em produção nunca muda.
PA_ARQ_OS_RELEASE="/etc/os-release"

# ------------------------------------------------------------
# Interpretador
# ------------------------------------------------------------

# checks_bash
#
# O instalador usa nameref (`local -n`), que exige bash 4.3.
# Ubuntu 22.04 traz o 5.1, então isto só dispara se alguém rodar
# com `sh mautic7.sh` num sistema onde /bin/sh não é bash.
checks_bash() {
	if [[ -z "${BASH_VERSION:-}" ]]; then
		ui_fatal \
			"Este script precisa do bash." \
			"Rode com: sudo bash ${0}"
	fi

	if [[ "${BASH_VERSINFO[0]}" -lt 4 ]] ||
		{ [[ "${BASH_VERSINFO[0]}" -eq 4 ]] && [[ "${BASH_VERSINFO[1]}" -lt 3 ]]; }; then
		ui_fatal \
			"Bash ${BASH_VERSION} é antigo demais (mínimo 4.3)." \
			"Ubuntu 22.04 e 24.04 trazem o bash 5."
	fi

	ui_ok "Bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
}

# ------------------------------------------------------------
# Privilégio
# ------------------------------------------------------------

# checks_root
#
# O script exige root e **não se re-executa sozinho com sudo**.
# Num script que acabou de pedir para a pessoa ler antes de
# rodar, escalar privilégio por conta própria passa a impressão
# errada. Detecta, explica e manda rodar de novo.
checks_root() {
	if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
		ui_fatal \
			"Este script precisa de privilégio de administrador." \
			"Rode de novo assim:" \
			"" \
			"    sudo bash ${0}" \
			"" \
			"Ele não chama sudo sozinho de propósito: um script que" \
			"pede para ser lido antes de rodar não deveria escalar" \
			"privilégio por conta própria."
	fi

	ui_ok "Executando como root"
}

# ------------------------------------------------------------
# Arquitetura
# ------------------------------------------------------------

checks_arquitetura() {
	local arq
	arq="$(uname -m)"

	if [[ "$arq" != "x86_64" ]]; then
		ui_fatal \
			"Arquitetura ${arq} não é suportada." \
			"O instalador foi testado apenas em x86_64 (amd64)." \
			"VPS ARM, como as instâncias Ampere, ficam de fora por ora."
	fi

	ui_ok "Arquitetura x86_64"
}

# ------------------------------------------------------------
# Sistema operacional
# ------------------------------------------------------------

# checks_versao_para_numero <versao>
#
# "24.04" vira 2404, para comparar com aritmética. O 10# evita
# que "08" seja lido como octal e derrube o script.
checks_versao_para_numero() {
	local versao="$1"
	local ano="${versao%%.*}"
	local mes="${versao##*.}"

	printf '%d\n' "$((10#${ano} * 100 + 10#${mes}))"
}

# checks_e_lts <versao>
#
# LTS do Ubuntu sai em ano par, sempre em abril.
checks_e_lts() {
	local versao="$1"
	local ano="${versao%%.*}"
	local mes="${versao##*.}"

	[[ "$mes" == "04" ]] && [[ $((10#${ano} % 2)) -eq 0 ]]
}

# checks_os_release <chave>
#
# Lê uma chave do /etc/os-release sem dar source no arquivo.
#
# O arquivo foi feito para ser carregado com `.`, mas aqui não
# vale a pena: depois do build.sh todas as libs dividem o mesmo
# escopo global, e ID, VERSION_ID e PRETTY_NAME são nomes
# genéricos demais para soltar nele.
checks_os_release() {
	local chave="$1"
	local valor

	valor="$(awk -F= -v k="$chave" \
		'$1 == k {sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print; exit}' \
		"$PA_ARQ_OS_RELEASE" 2>/dev/null)"

	printf '%s\n' "$valor"
}

# checks_sistema_operacional
#
# Ubuntu 22.04 e 24.04 passam direto. LTS mais nova que a lista
# avisa e pergunta, em vez de barrar: bloquear por padrão
# significa que o script morre sozinho no dia em que o 26.04
# sair. Qualquer outra coisa para.
checks_sistema_operacional() {
	if [[ ! -r "$PA_ARQ_OS_RELEASE" ]]; then
		ui_fatal \
			"Não consegui identificar o sistema operacional." \
			"O arquivo ${PA_ARQ_OS_RELEASE} não existe ou não pode ser lido." \
			"O instalador suporta Ubuntu 22.04 e 24.04."
	fi

	PA_SO_ID="$(checks_os_release ID)"
	PA_SO_VERSAO="$(checks_os_release VERSION_ID)"

	local nome
	nome="$(checks_os_release PRETTY_NAME)"
	[[ -z "$nome" ]] && nome="desconhecido"

	if [[ "$PA_SO_ID" != "ubuntu" ]]; then
		ui_fatal \
			"Sistema não suportado: ${nome}" \
			"O instalador suporta Ubuntu 22.04 e 24.04." \
			"Debian 12 entra numa versão futura, depois de testado."
	fi

	local suportada
	for suportada in "${PA_SO_SUPORTADOS[@]}"; do
		if [[ "$PA_SO_VERSAO" == "$suportada" ]]; then
			ui_ok "${nome}"
			return 0
		fi
	done

	local atual maior_suportada
	atual="$(checks_versao_para_numero "$PA_SO_VERSAO")"
	maior_suportada="$(checks_versao_para_numero "${PA_SO_SUPORTADOS[-1]}")"

	if [[ "$atual" -gt "$maior_suportada" ]] && checks_e_lts "$PA_SO_VERSAO"; then
		ui_aviso "${nome} é mais nova que as versões testadas."
		ui_detalhe "Testadas: Ubuntu ${PA_SO_SUPORTADOS[*]}."
		ui_detalhe "Deve funcionar, mas ninguém verificou ainda."

		if ! ui_confirmar "Continuar mesmo assim?" 1; then
			ui_fatal "Instalação cancelada."
		fi

		ui_ok "${nome} (não testada, seguindo a pedido)"
		return 0
	fi

	if [[ "$atual" -gt "$maior_suportada" ]]; then
		ui_fatal \
			"Sistema não suportado: ${nome}" \
			"Esta é uma versão intermediária do Ubuntu, com suporte curto." \
			"Use uma LTS: 22.04 ou 24.04."
	fi

	ui_fatal \
		"Sistema não suportado: ${nome}" \
		"Versão antiga demais. O instalador exige Ubuntu 22.04 ou 24.04."
}

# ------------------------------------------------------------
# Memória e disco
# ------------------------------------------------------------

checks_memoria() {
	local kb mb
	kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
	mb=$((kb / 1024))

	if [[ "$mb" -lt "$PA_RAM_MINIMA_MB" ]]; then
		ui_fatal \
			"RAM insuficiente: ${mb} MB." \
			"O mínimo é 2 GB, e 4 GB é o recomendado." \
			"Com menos que isso o Mautic é encerrado pelo sistema no" \
			"meio da instalação, sem mensagem de erro clara."
	fi

	ui_ok "RAM: ${mb} MB"

	if [[ "$mb" -lt "$PA_RAM_SWAP_MB" ]]; then
		ui_detalhe "Abaixo dos 4 GB recomendados; o swap será conferido adiante."
	fi
}

# checks_disco [caminho]
#
# Mede o sistema de arquivos que vai receber /var/lib/docker.
# Como o diretório pode não existir ainda, a medição é feita em
# /var, que existe sempre.
checks_disco() {
	local caminho="${1:-/var}"

	local mb
	mb="$(df -Pm "$caminho" | awk 'NR==2 {print $4}')"

	if [[ "$mb" -lt "$PA_DISCO_MINIMO_MB" ]]; then
		ui_fatal \
			"Espaço em disco insuficiente: ${mb} MB livres em ${caminho}." \
			"O mínimo é $((PA_DISCO_MINIMO_MB / 1024)) GB." \
			"As imagens do Mautic e do MariaDB somam perto de 2 GB, e o" \
			"resto é folga para o banco crescer."
	fi

	ui_ok "Disco livre em ${caminho}: $((mb / 1024)) GB"
}

# ------------------------------------------------------------
# Rede
# ------------------------------------------------------------

# checks_conectividade <host>
#
# Confere que dá para sair para a internet antes de gastar três
# minutos num apt que ia falhar no fim.
checks_conectividade() {
	local host="$1"

	if ! curl -fsS --max-time 15 -o /dev/null "https://${host}"; then
		ui_fatal \
			"Sem acesso a https://${host}" \
			"O instalador precisa baixar pacotes e imagens." \
			"Confira a conexão da VPS, o DNS e as regras de firewall."
	fi

	ui_ok "Conectividade com ${host}"
}

# ------------------------------------------------------------
# IP público
# ------------------------------------------------------------

# checks_ip_publico
#
# Descobre o IP local primeiro. O serviço externo é fallback
# para máquina atrás de NAT, e quando ele é usado o script diz
# na tela qual terceiro está sendo consultado: a documentação
# promete que nada é enviado, e consultar alguém carregando o IP
# da VPS merece ser anunciado.
checks_ip_publico() {
	local ip

	ip="$(ip -4 route get 1.1.1.1 2>/dev/null |
		awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"

	if [[ -n "$ip" ]] && ! checks_ip_privado "$ip"; then
		PA_IP_PUBLICO="$ip"
		ui_detalhe "IP público desta máquina: ${PA_IP_PUBLICO}"
		return 0
	fi

	ui_detalhe "IP local é privado; esta máquina parece estar atrás de NAT."
	ui_detalhe "Consultando https://api.ipify.org para descobrir o IP público."

	ip="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"

	if [[ -z "$ip" ]]; then
		ui_aviso "Não consegui descobrir o IP público desta máquina."
		return 1
	fi

	PA_IP_PUBLICO="$ip"
	ui_detalhe "IP público desta máquina: ${PA_IP_PUBLICO}"
}

checks_ip_privado() {
	local ip="$1"

	case "$ip" in
		10.* | 127.* | 192.168.*) return 0 ;;
		172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 0 ;;
		169.254.*) return 0 ;;
		*) return 1 ;;
	esac
}

# ------------------------------------------------------------
# CIDR
# ------------------------------------------------------------

# checks_ip_para_inteiro <ipv4>
#
# O 10# em cada octeto evita que "08" vire octal inválido.
checks_ip_para_inteiro() {
	local ip="$1"
	local a b c d

	IFS=. read -r a b c d <<<"$ip"

	printf '%u\n' "$(((10#${a} << 24) + (10#${b} << 16) + (10#${c} << 8) + 10#${d}))"
}

# checks_ip_em_faixa <ipv4> <cidr>
checks_ip_em_faixa() {
	local ip="$1"
	local cidr="$2"

	local rede="${cidr%/*}"
	local bits="${cidr#*/}"

	local ip_int rede_int mascara
	ip_int="$(checks_ip_para_inteiro "$ip")"
	rede_int="$(checks_ip_para_inteiro "$rede")"
	mascara=$((0xFFFFFFFF << (32 - bits) & 0xFFFFFFFF))

	[[ $((ip_int & mascara)) -eq $((rede_int & mascara)) ]]
}

# checks_ip_em_cdn <ipv4>
checks_ip_em_cdn() {
	local ip="$1"
	local faixa

	for faixa in "${PA_FAIXAS_CDN[@]}"; do
		if checks_ip_em_faixa "$ip" "$faixa"; then
			return 0
		fi
	done

	return 1
}

# ------------------------------------------------------------
# DNS
# ------------------------------------------------------------

# PA_DNS_RESULTADO é lida pela tela de resumo, que vive em outro
# arquivo, e uso entre arquivos não é enxergado pela análise.
# shellcheck disable=SC2034
# checks_dns <dominio>
#
# A checagem que mais economiza suporte: se o DNS aponta para
# outro lugar, o Let's Encrypt falha e a pessoa culpa o script.
#
# Usa getent, não dig: dnsutils não vem instalado no Ubuntu.
#
# O caso do Cloudflare com proxy ligado avisa em vez de barrar. O
# domínio resolve para um IP da Cloudflare, o DNS está certo, e
# abortar aqui reprovaria uma configuração correta que é comum
# neste público.
checks_dns() {
	local dominio="$1"

	local resolvidos=()
	mapfile -t resolvidos < <(getent ahostsv4 "$dominio" 2>/dev/null |
		awk '{print $1}' | sort -u)

	if [[ "${#resolvidos[@]}" -eq 0 ]]; then
		ui_fatal \
			"O domínio ${dominio} não resolve para nenhum IP." \
			"Crie um registro A apontando para ${PA_IP_PUBLICO:-o IP desta VPS}" \
			"e espere a propagação antes de rodar de novo." \
			"" \
			"Se o domínio é novo, isso costuma levar alguns minutos."
	fi

	if [[ -z "$PA_IP_PUBLICO" ]]; then
		PA_DNS_RESULTADO="não validado: IP desta VPS desconhecido"
		ui_aviso "IP público desconhecido; não dá para validar o DNS."
		ui_detalhe "Resolvido: ${resolvidos[*]}"
		return 0
	fi

	local ip
	for ip in "${resolvidos[@]}"; do
		if [[ "$ip" == "$PA_IP_PUBLICO" ]]; then
			PA_DNS_RESULTADO="aponta para esta VPS"
			ui_ok "DNS de ${dominio} aponta para esta VPS"
			return 0
		fi
	done

	for ip in "${resolvidos[@]}"; do
		if checks_ip_em_cdn "$ip"; then
			PA_DNS_RESULTADO="atrás de CDN, resolve para ${ip}"
			ui_aviso "${dominio} está atrás de CDN (Cloudflare)."
			ui_detalhe "Resolve para ${ip}, não para ${PA_IP_PUBLICO}."
			ui_detalhe "Isso está certo, e a instalação segue."
			ui_vazio
			ui_detalhe "Confira uma coisa no painel do Cloudflare: o modo de SSL"
			ui_detalhe "precisa estar em Full (strict). Em modo Flexible o Mautic"
			ui_detalhe "entra em laço de redirecionamento e não abre."
			ui_vazio
			return 0
		fi
	done

	ui_fatal \
		"O domínio ${dominio} aponta para outro servidor." \
		"" \
		"    resolve para:  ${resolvidos[*]}" \
		"    esta VPS é:    ${PA_IP_PUBLICO}" \
		"" \
		"Corrija o registro A no seu provedor de DNS e espere a" \
		"propagação. Sem isso o certificado SSL não é emitido." \
		"" \
		"Se você tem certeza de que está certo, rode de novo com" \
		"--skip-dns-check."
}

# ------------------------------------------------------------
# Validadores para ui_perguntar
#
# Explicam o problema na tela e devolvem 1; ui_perguntar repete
# a pergunta.
# ------------------------------------------------------------

checks_validar_dominio() {
	local dominio="$1"

	if [[ "$dominio" =~ ^https?:// ]]; then
		ui_aviso "Informe só o domínio, sem http:// nem https://."
		return 1
	fi

	if [[ "$dominio" == *"/"* ]]; then
		ui_aviso "Informe só o domínio, sem barra nem caminho."
		return 1
	fi

	if [[ ! "$dominio" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
		ui_aviso "\"${dominio}\" não parece um domínio válido."
		ui_detalhe "Exemplo: mautic.suaempresa.com.br"
		return 1
	fi

	# Não há checagem de "isto é domínio raiz". Distinguir
	# exemplo.com.br de exemplo.com exige uma Public Suffix List,
	# e qualquer atalho fica arbitrário: contar pontos rejeitaria
	# exemplo.com.br e aceitaria exemplo.com, que é o mesmo caso.
	# Instalar na raiz é decisão de quem instala.
	return 0
}

checks_validar_email() {
	local email="$1"

	if [[ ! "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
		ui_aviso "\"${email}\" não parece um e-mail válido."
		return 1
	fi

	return 0
}

# ------------------------------------------------------------
# Orquestração
# ------------------------------------------------------------

# checks_sistema
#
# Etapa 1: o que não depende do cenário, na ordem de custo
# crescente. As checagens de porta e de DNS ficam de fora porque
# dependem do cenário detectado e do domínio informado, e são
# chamadas pelo orquestrador mais adiante.
checks_sistema() {
	ui_secao "Conferindo o servidor"

	checks_bash
	checks_root
	checks_arquitetura
	checks_sistema_operacional
	checks_memoria
	checks_disco
}

# ============================================================
# lib/portas.sh
# ============================================================

# shellcheck shell=bash
#
# ============================================================
# lib/portas.sh
# Descoberta de portas em escuta.
#
# Depende de lib/ui.sh.
#
# Vive fora de lib/checks.sh porque só o instalador de base
# precisa disto: quem decide se 80 e 443 estão livres é quem vai
# subir o Traefik. Um instalador de ferramenta chega numa máquina
# onde o proxy já ocupa as duas, legitimamente, e carregar esta
# cadeia inteira no artefato dele seria peso morto.
#
# É também o único arquivo que instala pacote fora do módulo de
# base propriamente dito, e a exceção está documentada em
# portas_instalar_iproute2.
# ============================================================

# Arquivos do procfs. Existem como variável para os testes
# poderem apontar o parser para exemplos.
PA_PORTAS_PROC_TCP=("/proc/net/tcp" "/proc/net/tcp6")

# portas_ferramenta
#
# Escolhe como listar portas em escuta, na ordem de preferência.
#
# O `ss` vem no iproute2 e está em toda imagem Ubuntu Server que
# se conhece, mas "que se conhece" não é garantia: imagem enxuta
# de provedor às vezes corta o pacote, e aí a checagem mais
# importante do cenário 1 falharia em silêncio, deixando o
# Traefik subir contra uma porta ocupada.
#
# O último recurso é /proc/net/tcp, que faz parte do procfs e
# existe em qualquer Linux. Por isso a cadeia praticamente nunca
# chega a lugar nenhum.
portas_ferramenta() {
	if command -v ss >/dev/null 2>&1; then
		printf 'ss\n'
	elif command -v netstat >/dev/null 2>&1; then
		printf 'netstat\n'
	elif [[ -r "${PA_PORTAS_PROC_TCP[0]}" ]]; then
		printf 'proc\n'
	else
		printf '\n'
	fi
}

# portas_ocupada <porta> <ferramenta>
#
# Devolve 0 quando alguém está escutando na porta.
portas_ocupada() {
	local porta="$1"
	local ferramenta="$2"

	case "$ferramenta" in
		ss)
			ss -ltn "sport = :${porta}" 2>/dev/null | grep -q LISTEN
			;;
		netstat)
			netstat -ltn 2>/dev/null |
				awk -v p="$porta" '
					NR > 2 {
						n = split($4, a, ":")
						if (a[n] == p) { encontrou = 1; exit }
					}
					END { exit !encontrou }
				'
			;;
		proc)
			portas_ocupada_proc "$porta"
			;;
		*)
			return 1
			;;
	esac
}

# portas_ocupada_proc <porta>
#
# Lê o procfs direto. O endereço local vem como hexadecimal
# ("00000000:0050"), e 0A é o estado LISTEN. Precisa olhar tcp e
# tcp6: um serviço que escuta só em IPv6 ocupa a porta do mesmo
# jeito.
portas_ocupada_proc() {
	local porta="$1"

	local hex
	printf -v hex '%04X' "$porta"

	local arquivo
	for arquivo in "${PA_PORTAS_PROC_TCP[@]}"; do
		[[ -r "$arquivo" ]] || continue

		if awk -v p="$hex" '
			$4 == "0A" {
				split($2, a, ":")
				if (a[2] == p) { encontrou = 1; exit }
			}
			END { exit !encontrou }
		' "$arquivo"; then
			return 0
		fi
	done

	return 1
}

# portas_quem_ocupa <porta> <ferramenta>
#
# Melhor esforço para nomear o processo. Serve só para a
# mensagem de erro: saber que "a porta 80 está ocupada" não
# ajuda ninguém, saber que é o apache2 resolve o problema.
portas_quem_ocupa() {
	local porta="$1"
	local ferramenta="$2"

	local quem=""

	case "$ferramenta" in
		ss)
			quem="$(ss -ltnp "sport = :${porta}" 2>/dev/null |
				awk 'NR > 1 {print $NF; exit}')"
			;;
		netstat)
			quem="$(netstat -ltnp 2>/dev/null |
				awk -v p="$porta" '
					NR > 2 {
						n = split($4, a, ":")
						if (a[n] == p) { print $NF; exit }
					}
				')"
			;;
	esac

	if [[ -z "$quem" ]]; then
		quem="processo não identificado"
		[[ "$ferramenta" == "proc" ]] &&
			quem+=" (instale o iproute2 para ver o nome)"
	fi

	printf '%s\n' "$quem"
}

# portas_instalar_iproute2
#
# Exceção à regra de que este módulo não altera a máquina.
#
# Só é chamada quando não existe ss, nem netstat, nem
# /proc/net/tcp legível — combinação que praticamente não
# acontece num Linux. Fica aqui porque a alternativa seria pular
# a checagem de portas, e subir o Traefik contra uma porta
# ocupada é exatamente o tipo de falha silenciosa que este
# projeto tenta evitar.
portas_instalar_iproute2() {
	ui_aviso "Nenhuma forma de listar portas em escuta nesta máquina."
	ui_detalhe "Instalando o iproute2 para conseguir conferir as portas 80 e 443."

	if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1; then
		ui_aviso "Falha ao atualizar a lista de pacotes."
		return 1
	fi

	if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iproute2 >/dev/null 2>&1; then
		ui_aviso "Falha ao instalar o iproute2."
		return 1
	fi

	ui_ok "iproute2 instalado"
}

# portas_livres [pode_instalar]
#
# Só nos cenários 1 e 1.5. No cenário 2 o Traefik ocupa 80 e 443
# legitimamente, e esta checagem é pulada pelo orquestrador.
#
# pode_instalar=1 autoriza a instalação do iproute2 como último
# recurso. O orquestrador só passa 1 no cenário 1, onde a máquina
# vai receber pacote de qualquer jeito.
portas_livres() {
	local pode_instalar="${1:-0}"

	local ferramenta
	ferramenta="$(portas_ferramenta)"

	if [[ -z "$ferramenta" ]]; then
		if [[ "$pode_instalar" == "1" ]] && portas_instalar_iproute2; then
			ferramenta="$(portas_ferramenta)"
		fi
	fi

	if [[ -z "$ferramenta" ]]; then
		ui_fatal \
			"Não consigo conferir se as portas 80 e 443 estão livres." \
			"Não há ss, netstat nem /proc/net/tcp nesta máquina." \
			"Instale o iproute2 e rode de novo:" \
			"" \
			"    sudo apt-get install -y iproute2"
	fi

	[[ "$ferramenta" != "ss" ]] &&
		ui_detalhe "Usando ${ferramenta} para listar portas (ss indisponível)."

	local porta ocupadas=()
	for porta in 80 443; do
		if portas_ocupada "$porta" "$ferramenta"; then
			ocupadas+=("$porta")
		fi
	done

	if [[ "${#ocupadas[@]}" -eq 0 ]]; then
		ui_ok "Portas 80 e 443 livres"
		return 0
	fi

	ui_erro "Portas ocupadas: ${ocupadas[*]}"
	ui_vazio
	ui_info "Quem está ouvindo:"

	for porta in "${ocupadas[@]}"; do
		ui_detalhe "porta ${porta}: $(portas_quem_ocupa "$porta" "$ferramenta")"
	done

	ui_fatal \
		"O Traefik precisa das portas 80 e 443." \
		"Provavelmente há um Apache ou Nginx instalado direto no" \
		"sistema. Pare e desabilite o serviço, ou use uma VPS limpa." \
		"O instalador não desliga serviço de ninguém."
}

# ============================================================
# lib/sistema.sh
# ============================================================

# shellcheck shell=bash
#
# ============================================================
# lib/sistema.sh
# Rotinas que mexem no sistema operacional, fora do Docker.
#
# Depende de lib/ui.sh e das constantes de lib/checks.sh.
#
# Existe para separar duas coisas que estavam se misturando:
# checks.sh lê e decide, docker.sh e traefik.sh cuidam de
# containers, e o swap não é nem um nem outro. Conforme este
# arquivo receber outras rotinas de máquina — fuso, limites de
# arquivo, ajuste de kernel — elas vêm para cá.
# ============================================================

# ------------------------------------------------------------
# Constantes
# ------------------------------------------------------------

PA_SWAP_ARQUIVO="/swapfile"
PA_SWAP_TAMANHO_MB=2048

# Folga exigida em disco além do próprio swapfile. Criar um swap
# que enche a partição troca um problema por outro pior.
PA_SWAP_FOLGA_MB=2048

PA_FSTAB="/etc/fstab"

# Preenchida por sistema_criar_swap, lida pelo bloco final em
# main.sh: o CLAUDE.md exige registrar no fim que o swap foi
# criado e onde. É interface pública do módulo, como PA_SO_ID e
# PA_IP_PUBLICO em checks.sh.
PA_SWAP_CRIADO=""

# ------------------------------------------------------------
# Leitura
# ------------------------------------------------------------

# sistema_ram_mb
sistema_ram_mb() {
	local kb
	kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"

	printf '%d\n' "$((kb / 1024))"
}

# sistema_tem_swap
#
# Verdadeiro havendo qualquer swap ativo, de qualquer tipo:
# arquivo, partição ou zram. Se já existe, não é problema nosso.
sistema_tem_swap() {
	local total
	total="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"

	[[ "${total:-0}" -gt 0 ]]
}

# sistema_disco_livre_mb <caminho>
sistema_disco_livre_mb() {
	local caminho="${1:-/}"

	df -Pm "$caminho" | awk 'NR==2 {print $4}'
}

# ------------------------------------------------------------
# Swap
# ------------------------------------------------------------

# sistema_precisa_swap
#
# Verdadeiro quando a máquina tem pouca RAM e nenhum swap.
#
# O limiar é PA_RAM_SWAP_MB, que vale 3800 e não 4096: uma VPS
# vendida como "4 GB" reporta 3915 MB depois do que o kernel
# reserva, e comparar com 4096 daria swap a toda máquina de 4 GB.
sistema_precisa_swap() {
	local ram
	ram="$(sistema_ram_mb)"

	[[ "$ram" -lt "$PA_RAM_SWAP_MB" ]] && ! sistema_tem_swap
}

# sistema_criar_swap [no_swap]
#
# Cria um swapfile de 2 GB quando a máquina precisa, anunciando
# na tela. `--no-swap` desliga, passando 1.
#
# Motivo: 2 GB é o piso do README, e MariaDB mais três containers
# PHP nesse espaço colocam o cache warmup do Symfony em risco de
# OOM. OOM não deixa mensagem clara — o container simplesmente
# morre, e essa é uma das falhas mais confusas que existem.
#
# Criar swap é aditivo, não viola a regra de nada destrutivo.
# Nunca mexe em swap que já existe e nunca reescreve o fstab
# inteiro: só acrescenta uma linha, se ela ainda não estiver lá.
sistema_criar_swap() {
	local desligado="${1:-0}"

	local ram
	ram="$(sistema_ram_mb)"

	if [[ "$desligado" == "1" ]]; then
		if sistema_precisa_swap; then
			ui_aviso "Esta máquina tem ${ram} MB de RAM e nenhum swap."
			ui_detalhe "Criação de swap desligada por --no-swap."
			ui_detalhe "Se o Mautic morrer durante a instalação, é provável"
			ui_detalhe "que seja falta de memória, e o log não vai dizer isso."
		fi
		return 0
	fi

	if sistema_tem_swap; then
		ui_ok "Swap já ativo nesta máquina"
		return 0
	fi

	if [[ "$ram" -ge "$PA_RAM_SWAP_MB" ]]; then
		ui_ok "RAM suficiente (${ram} MB); swap dispensado"
		return 0
	fi

	# Idempotência: arquivo já lá, de uma execução anterior que
	# não chegou a ativar. Reaproveita em vez de criar um segundo.
	if [[ -e "$PA_SWAP_ARQUIVO" ]]; then
		ui_aviso "${PA_SWAP_ARQUIVO} já existe, mas não está ativo."
		ui_detalhe "Tentando ativar o que já está lá, sem criar outro."
		sistema_ativar_swap
		return $?
	fi

	local livre
	livre="$(sistema_disco_livre_mb /)"

	if [[ "$livre" -lt $((PA_SWAP_TAMANHO_MB + PA_SWAP_FOLGA_MB)) ]]; then
		ui_aviso "Espaço insuficiente para criar swap: ${livre} MB livres."
		ui_detalhe "Seriam necessários $((PA_SWAP_TAMANHO_MB + PA_SWAP_FOLGA_MB)) MB."
		ui_detalhe "Seguindo sem swap. Fique atento a travamentos."
		return 0
	fi

	ui_passo "Criando swap de $((PA_SWAP_TAMANHO_MB / 1024)) GB"
	ui_detalhe "Esta máquina tem ${ram} MB de RAM e nenhum swap."
	ui_detalhe "Sem swap, o Mautic corre risco de ser encerrado pelo"
	ui_detalhe "sistema no meio da instalação, sem mensagem de erro."

	if ! sistema_alocar_swapfile; then
		ui_aviso "Não consegui criar o arquivo de swap."
		ui_detalhe "Seguindo sem ele."
		rm -f "$PA_SWAP_ARQUIVO"
		return 0
	fi

	chmod 600 "$PA_SWAP_ARQUIVO"

	if ! mkswap "$PA_SWAP_ARQUIVO" >/dev/null 2>&1; then
		ui_aviso "Falha ao formatar o arquivo de swap. Seguindo sem ele."
		rm -f "$PA_SWAP_ARQUIVO"
		return 0
	fi

	sistema_ativar_swap
}

# sistema_alocar_swapfile
#
# fallocate é instantâneo, mas não funciona em todo sistema de
# arquivos — em alguns tipos ele cria um arquivo esparso que o
# mkswap recusa. O dd é lento e sempre funciona, então fica de
# reserva.
sistema_alocar_swapfile() {
	if fallocate -l "${PA_SWAP_TAMANHO_MB}M" "$PA_SWAP_ARQUIVO" 2>/dev/null; then
		return 0
	fi

	ui_detalhe "fallocate indisponível aqui; usando dd, que é mais lento."

	dd if=/dev/zero of="$PA_SWAP_ARQUIVO" \
		bs=1M count="$PA_SWAP_TAMANHO_MB" \
		status=none 2>/dev/null
}

# sistema_ativar_swap
#
# Ativa e persiste no fstab. Sem a linha no fstab o swap some no
# primeiro reboot, e o problema volta meses depois sem ninguém
# ligar uma coisa à outra.
sistema_ativar_swap() {
	if ! swapon "$PA_SWAP_ARQUIVO" 2>/dev/null; then
		ui_aviso "Não consegui ativar o swap. Seguindo sem ele."
		return 0
	fi

	sistema_persistir_swap_fstab

	# Lida pelo bloco final em main.sh; o shellcheck não enxerga
	# esse uso analisando este arquivo sozinho.
	# shellcheck disable=SC2034
	PA_SWAP_CRIADO="$PA_SWAP_ARQUIVO"
	ui_ok "Swap de $((PA_SWAP_TAMANHO_MB / 1024)) GB ativo em ${PA_SWAP_ARQUIVO}"
}

# sistema_persistir_swap_fstab
#
# Acrescenta a linha só se ela ainda não existir. Nunca reescreve
# nem reordena o arquivo: o fstab é dos poucos arquivos em que um
# erro deixa a máquina sem subir.
sistema_persistir_swap_fstab() {
	if grep -qE "^[^#]*${PA_SWAP_ARQUIVO}[[:space:]]" "$PA_FSTAB" 2>/dev/null; then
		ui_detalhe "Já havia linha para ${PA_SWAP_ARQUIVO} no fstab."
		return 0
	fi

	if printf '%s none swap sw 0 0\n' "$PA_SWAP_ARQUIVO" >>"$PA_FSTAB"; then
		ui_detalhe "Registrado no ${PA_FSTAB}, para sobreviver a reboot."
	else
		ui_aviso "Swap ativo, mas não consegui registrar no ${PA_FSTAB}."
		ui_detalhe "Ele vai sumir no próximo reboot desta máquina."
	fi
}

# ============================================================
# lib/docker.sh
# ============================================================

# shellcheck shell=bash
#
# ============================================================
# lib/docker.sh
# Detecção e instalação do Docker.
#
# Depende de lib/ui.sh e de checks_os_release, de lib/checks.sh.
#
# Os comandos aqui são os que rodaram na VPS de teste em
# 2026-09-01 e estão registrados em "Comandos validados em VPS"
# no CLAUDE.md. Resultado daquela execução: Docker 29.7.2,
# Compose v5.5.0, serviço enabled e active, Swarm inactive.
#
# Vale para este arquivo a mesma regra de lib/ui.sh: depois do
# build.sh tudo divide o mesmo escopo global, então todo nome
# público leva prefixo docker_ ou PA_, e não há `return` fora de
# função.
# ============================================================

# ------------------------------------------------------------
# Detecção
# ------------------------------------------------------------

docker_binario_presente() {
	command -v docker >/dev/null 2>&1
}

# docker_daemon_ok
#
# Binário presente não significa daemon de pé. Um `docker` que
# existe mas cujo serviço está parado produz erro de socket que
# não diz nada para quem está começando.
docker_daemon_ok() {
	docker info >/dev/null 2>&1
}

# docker_presente
#
# O que a detecção de cenário considera "Docker presente":
# binário instalado e daemon respondendo.
docker_presente() {
	docker_binario_presente && docker_daemon_ok
}

docker_compose_presente() {
	docker compose version >/dev/null 2>&1
}

# docker_swarm_ativo
#
# Verdadeiro quando a máquina está em Swarm, como manager ou
# worker. O estado "pending" também conta: a máquina já saiu do
# Compose puro.
docker_swarm_ativo() {
	local estado
	estado="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"

	[[ "$estado" == "active" || "$estado" == "pending" ]]
}

# docker_checar_swarm
#
# O instalador assume Compose puro. Suportar os dois modos dobra
# a superfície de bug: `depends_on` com `condition:
# service_healthy` é ignorado no Swarm, e rede overlay só aceita
# container externo se tiver sido criada como `attachable`.
docker_checar_swarm() {
	docker_binario_presente || return 0

	if docker_swarm_ativo; then
		ui_fatal \
			"Esta máquina está em modo Swarm." \
			"O instalador trabalha com Docker Compose puro e não se" \
			"adapta ao Swarm, onde depends_on com condition é ignorado" \
			"e rede overlay exige ser attachable." \
			"" \
			"Use uma VPS sem Swarm, ou instale o Mautic manualmente" \
			"como serviço do seu stack."
	fi
}

docker_versao() {
	docker version --format '{{.Server.Version}}' 2>/dev/null ||
		printf 'desconhecida\n'
}

docker_compose_versao() {
	docker compose version --short 2>/dev/null ||
		printf 'desconhecida\n'
}

# ============================================================
# lib/docker_instalar.sh
# ============================================================

# shellcheck shell=bash
#
# ============================================================
# lib/docker_instalar.sh
# Instalação do Docker e criação de rede.
#
# Depende de lib/ui.sh, lib/docker.sh e de checks_os_release.
#
# Só entra no instalador de base. Um instalador de ferramenta
# detecta o Docker, mas nunca o instala: se estiver faltando, ele
# manda rodar a base e encerra. Assim a instalação do Docker
# existe em um lugar só, e os próximos instaladores a herdam em
# vez de recriá-la.
# ============================================================
# ------------------------------------------------------------
# Constantes
# ------------------------------------------------------------

# Pacotes do repositório oficial. O docker-compose-plugin é o que
# entrega `docker compose` como subcomando; o pacote antigo
# docker-compose, com hífen, é outro projeto e não serve.
PA_DOCKER_PACOTES=(
	docker-ce
	docker-ce-cli
	containerd.io
	docker-buildx-plugin
	docker-compose-plugin
)

PA_DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
PA_DOCKER_LISTA="/etc/apt/sources.list.d/docker.list"
PA_DOCKER_GPG_URL="https://download.docker.com/linux/ubuntu/gpg"
PA_DOCKER_REPO_URL="https://download.docker.com/linux/ubuntu"

# ------------------------------------------------------------
# Instalação
# ------------------------------------------------------------

# docker_instalar
#
# Método oficial de repositório, e não o script de conveniência
# do get.docker.com.
#
# Motivo, registrado no CLAUDE.md: o repositório é auditável,
# recebe atualização por `apt upgrade` junto com o resto do
# sistema, e não pede que a pessoa execute mais um script remoto
# logo depois de este instalador ter pedido para ela ler scripts
# antes de rodar.
docker_instalar() {
	ui_passo "Instalando o Docker"

	local codinome
	codinome="$(checks_os_release VERSION_CODENAME)"

	if [[ -z "$codinome" ]]; then
		ui_fatal \
			"Não consegui descobrir o codinome desta versão do Ubuntu." \
			"Sem ele não dá para montar a linha do repositório do Docker."
	fi

	export DEBIAN_FRONTEND=noninteractive

	ui_info "Atualizando a lista de pacotes"
	apt-get update -qq >/dev/null 2>&1 ||
		ui_fatal \
			"Falha ao atualizar a lista de pacotes." \
			"Confira a conexão da VPS e rode: apt-get update"

	ui_info "Instalando pré-requisitos"
	apt-get install -y -qq ca-certificates curl >/dev/null 2>&1 ||
		ui_fatal "Falha ao instalar ca-certificates e curl."

	ui_info "Adicionando a chave e o repositório oficiais do Docker"
	install -m 0755 -d /etc/apt/keyrings

	curl -fsSL "$PA_DOCKER_GPG_URL" -o "$PA_DOCKER_KEYRING" ||
		ui_fatal \
			"Falha ao baixar a chave do repositório do Docker." \
			"Origem: ${PA_DOCKER_GPG_URL}"

	chmod a+r "$PA_DOCKER_KEYRING"

	printf 'deb [arch=%s signed-by=%s] %s %s stable\n' \
		"$(dpkg --print-architecture)" \
		"$PA_DOCKER_KEYRING" \
		"$PA_DOCKER_REPO_URL" \
		"$codinome" \
		>"$PA_DOCKER_LISTA"

	ui_info "Atualizando a lista com o repositório do Docker"
	apt-get update -qq >/dev/null 2>&1 ||
		ui_fatal \
			"Falha ao ler o repositório do Docker." \
			"Verifique ${PA_DOCKER_LISTA}"

	ui_info "Instalando Docker e o plugin do Compose"
	apt-get install -y -qq "${PA_DOCKER_PACOTES[@]}" >/dev/null 2>&1 ||
		ui_fatal \
			"Falha ao instalar os pacotes do Docker." \
			"Rode à mão para ver o erro:" \
			"" \
			"    apt-get install ${PA_DOCKER_PACOTES[*]}"

	# O pacote docker-ce já cria e habilita o serviço; não é
	# preciso systemctl enable --now. Confirmado no teste.
	ui_aguardar_ate "Aguardando o daemon do Docker" 60 docker_daemon_ok ||
		ui_fatal \
			"O Docker foi instalado mas o daemon não respondeu." \
			"Diagnostique com:" \
			"" \
			"    systemctl status docker" \
			"    journalctl -u docker -n 50"

	ui_ok "Docker $(docker_versao), Compose $(docker_compose_versao)"
}

# docker_garantir
#
# Ponto de entrada da etapa 7 para o Docker. Idempotente: se já
# estiver tudo lá, não mexe em nada e diz o que encontrou.
#
# Cobre também o cenário 1.5, em que o Docker existe mas o plugin
# do Compose não — caso de quem instalou pelo pacote da
# distribuição em vez do repositório oficial.
docker_garantir() {
	if docker_presente && docker_compose_presente; then
		ui_ok "Docker $(docker_versao) e Compose $(docker_compose_versao) já instalados"
		return 0
	fi

	if docker_binario_presente && ! docker_daemon_ok; then
		ui_fatal \
			"O Docker está instalado mas o daemon não responde." \
			"O instalador não mexe em serviço que já existe nesta máquina." \
			"Suba o daemon e rode de novo:" \
			"" \
			"    systemctl start docker"
	fi

	if docker_presente && ! docker_compose_presente; then
		ui_aviso "Docker presente, mas sem o plugin do Compose."
		ui_detalhe "Instalando o repositório oficial para obter o plugin."
	fi

	docker_instalar
}

# ------------------------------------------------------------
# Rede
# ------------------------------------------------------------

docker_rede_existe() {
	local nome="$1"

	docker network inspect "$nome" >/dev/null 2>&1
}

# docker_criar_rede <nome>
#
# Operação aditiva e idempotente, das permitidas pela regra de
# nada destrutivo. Rede que já existe é reaproveitada como está:
# recriar derrubaria os containers de outra pessoa que já estão
# nela.
docker_criar_rede() {
	local nome="$1"

	if docker_rede_existe "$nome"; then
		ui_ok "Rede ${nome} já existe"
		return 0
	fi

	if ! docker network create "$nome" >/dev/null 2>&1; then
		ui_fatal \
			"Falha ao criar a rede ${nome}." \
			"Rode à mão para ver o erro:" \
			"" \
			"    docker network create ${nome}"
	fi

	ui_ok "Rede ${nome} criada"
}

# ============================================================
# lib/traefik.sh
# ============================================================

# shellcheck shell=bash
#
# ============================================================
# lib/traefik.sh
# Detecção do Traefik em execução.
#
# Depende de lib/ui.sh e lib/docker.sh.
#
# É compartilhado pelos dois instaladores. A base usa para não
# instalar um proxy sobre outro; o instalador de ferramenta usa
# para descobrir os nomes de rede, entrypoint e certresolver que
# precisa citar nos labels. A instalação do Traefik mora em
# lib/traefik_instalar.sh e só entra no artefato da base.
#
# É esta detecção que evita o modo de falha mais caro do projeto:
# cravar os nomes padrão faz o container subir, o Mautic
# funcionar e o domínio devolver 404 sem nenhuma mensagem.
#
# Validada em VPS contra tres Traefiks: o nosso por flags de CLI,
# um de terceiro configurado por arquivo estatico com nomes
# arbitrarios, e um sem certresolver nenhum.
# ============================================================

# ------------------------------------------------------------
# Constantes
# ------------------------------------------------------------

# Redes que nunca são a rede do proxy.
PA_TRAEFIK_REDES_IGNORADAS=("bridge" "host" "none")

# Preenchidas pela detecção. Cada valor anda junto com a origem,
# porque a tela de confirmação precisa dizer de onde tirou cada
# coisa — "detectado" sem procedência não ajuda a decidir.
PA_TRAEFIK_CONTAINER=""
PA_TRAEFIK_ENTRYPOINT=""
PA_TRAEFIK_ENTRYPOINT_ORIGEM=""
PA_TRAEFIK_CERTRESOLVER=""
PA_TRAEFIK_CERTRESOLVER_ORIGEM=""
PA_TRAEFIK_NETWORK=""
PA_TRAEFIK_NETWORK_ORIGEM=""
PA_TRAEFIK_HOST_MODE=0

# ------------------------------------------------------------
# Identificação do container
# ------------------------------------------------------------

# traefik_listar_containers
#
# Identificação por imagem, como decidido: container em execução
# cuja imagem casa com "traefik".
traefik_listar_containers() {
	docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null |
		awk -F'\t' 'tolower($2) ~ /traefik/ {print $1}'
}

# traefik_detectar_container
#
# Havendo mais de um, pergunta. Havendo zero mas alguém segurando
# o 443, mostra quem é e para — sem inventar.
traefik_detectar_container() {
	local encontrados=()
	mapfile -t encontrados < <(traefik_listar_containers)

	if [[ "${#encontrados[@]}" -eq 0 ]]; then
		return 1
	fi

	ui_escolher PA_TRAEFIK_CONTAINER \
		"Mais de um Traefik em execução. Qual é o proxy desta máquina?" \
		"${encontrados[@]}"

	return 0
}

# traefik_inspect <container> <template_go>
traefik_inspect() {
	local container="$1"
	local template="$2"

	docker inspect --format "$template" "$container" 2>/dev/null || true
}

# traefik_argumentos <container>
#
# Junta Entrypoint, Cmd e Args numa linha só. Instaladores
# diferentes espalham as flags entre os três campos, e procurar
# em apenas um deles perde configuração.
traefik_argumentos() {
	local container="$1"

	traefik_inspect "$container" \
		'{{range .Config.Entrypoint}}{{.}} {{end}}{{range .Config.Cmd}}{{.}} {{end}}{{range .Args}}{{.}} {{end}}'
}

# traefik_ambiente <container>
traefik_ambiente() {
	local container="$1"

	traefik_inspect "$container" '{{range .Config.Env}}{{.}}
{{end}}'
}

# traefik_labels <container>
#
# Os $k e $v abaixo são do template do Go, não do shell: aspas
# simples são o que se quer aqui.
# shellcheck disable=SC2016
traefik_labels() {
	local container="$1"

	traefik_inspect "$container" '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}
{{end}}'
}

# traefik_config_estatica <container>
#
# Lê o arquivo de configuração de dentro do container.
#
# É a fonte que uma detecção ingênua ignora, e é justamente a que
# os instaladores populares mais usam. Quem só olha flags de CLI
# passa direto por ela e conclui que não há certresolver nenhum.
traefik_config_estatica() {
	local container="$1"
	local caminho

	for caminho in \
		/etc/traefik/traefik.yml \
		/etc/traefik/traefik.yaml \
		/traefik.yml \
		/traefik.yaml \
		/config/traefik.yml \
		/config/traefik.yaml; do
		local conteudo
		conteudo="$(docker exec "$container" cat "$caminho" 2>/dev/null || true)"

		if [[ -n "$conteudo" ]]; then
			printf '%s\n' "$conteudo"
			return 0
		fi
	done

	return 1
}

# ------------------------------------------------------------
# Entrypoint
# ------------------------------------------------------------

# traefik_detectar_entrypoint <container>
#
# Procura o entrypoint ligado à porta 443, que é o que o label do
# Mautic precisa citar. O nome fica entre "entrypoints." e
# ".address".
traefik_detectar_entrypoint() {
	local container="$1"
	local nome=""

	nome="$(traefik_argumentos "$container" |
		grep -oE -- '--entry[pP]oints\.[A-Za-z0-9_-]+\.address=:443' |
		head -1 |
		sed -E 's/.*entry[pP]oints\.([A-Za-z0-9_-]+)\.address.*/\1/')"

	if [[ -n "$nome" ]]; then
		PA_TRAEFIK_ENTRYPOINT="$nome"
		PA_TRAEFIK_ENTRYPOINT_ORIGEM="flags de linha de comando"
		return 0
	fi

	# O Traefik aceita configuração por variável de ambiente:
	# TRAEFIK_ENTRYPOINTS_<NOME>_ADDRESS=:443
	nome="$(traefik_ambiente "$container" |
		grep -oE '^TRAEFIK_ENTRYPOINTS_[A-Z0-9_]+_ADDRESS=:443' |
		head -1 |
		sed -E 's/^TRAEFIK_ENTRYPOINTS_(.+)_ADDRESS=.*/\1/')"

	if [[ -n "$nome" ]]; then
		PA_TRAEFIK_ENTRYPOINT="${nome,,}"
		PA_TRAEFIK_ENTRYPOINT_ORIGEM="variável de ambiente do container"
		return 0
	fi

	# Labels do próprio container. Muita instalação expõe o
	# dashboard do Traefik por um roteador no próprio container, e
	# esse roteador cita o entrypoint HTTPS.
	#
	# Heurística: o label pode listar vários separados por vírgula,
	# como "web,websecure", e daí não dá para saber qual é o 443.
	# Fica o último, que pela convenção é o seguro. As fontes
	# acima, que casam com address=:443, são exatas e vêm antes.
	nome="$(traefik_labels "$container" |
		grep -oE '^traefik\.http\.routers\.[A-Za-z0-9_-]+\.entry[pP]oints=.+' |
		head -1 |
		sed -E 's/.*entry[pP]oints=//' |
		tr ',' '\n' |
		tail -1 |
		tr -d '[:space:]')"

	if [[ -n "$nome" ]]; then
		PA_TRAEFIK_ENTRYPOINT="$nome"
		PA_TRAEFIK_ENTRYPOINT_ORIGEM="label do container do Traefik"
		return 0
	fi

	# Arquivo estático: bloco entryPoints com address ":443".
	local config
	if config="$(traefik_config_estatica "$container")"; then
		nome="$(printf '%s\n' "$config" |
			awk '
				/^[[:space:]]*entry[pP]oints:/ { dentro = 1; next }
				dentro && /^[^[:space:]]/      { dentro = 0 }
				dentro && /^[[:space:]]{2}[A-Za-z0-9_-]+:/ {
					gsub(/[[:space:]:]/, "", $0); atual = $0
				}
				dentro && /address:/ && /:443/ { print atual; exit }
			')"

		if [[ -n "$nome" ]]; then
			PA_TRAEFIK_ENTRYPOINT="$nome"
			PA_TRAEFIK_ENTRYPOINT_ORIGEM="arquivo estático dentro do container"
			return 0
		fi
	fi

	return 1
}

# ------------------------------------------------------------
# Certresolver
# ------------------------------------------------------------

# traefik_detectar_certresolver <container>
#
# Ausência é resposta legítima, não falha.
#
# Quem termina TLS no Cloudflare não tem certresolver nenhum, e
# preencher "letsencrypt" no chute produz um roteador que não
# sobe. É o outro lado do falso positivo de DNS tratado em
# checks.sh, e os dois precisam ser coerentes.
traefik_detectar_certresolver() {
	local container="$1"
	local nome=""

	nome="$(traefik_argumentos "$container" |
		grep -oE -- '--certificates[rR]esolvers\.[A-Za-z0-9_-]+\.acme' |
		head -1 |
		sed -E 's/.*certificates[rR]esolvers\.([A-Za-z0-9_-]+)\.acme.*/\1/')"

	if [[ -n "$nome" ]]; then
		PA_TRAEFIK_CERTRESOLVER="$nome"
		PA_TRAEFIK_CERTRESOLVER_ORIGEM="flags de linha de comando"
		return 0
	fi

	nome="$(traefik_ambiente "$container" |
		grep -oE '^TRAEFIK_CERTIFICATESRESOLVERS_[A-Z0-9_]+_ACME' |
		head -1 |
		sed -E 's/^TRAEFIK_CERTIFICATESRESOLVERS_(.+)_ACME.*/\1/')"

	if [[ -n "$nome" ]]; then
		PA_TRAEFIK_CERTRESOLVER="${nome,,}"
		PA_TRAEFIK_CERTRESOLVER_ORIGEM="variável de ambiente do container"
		return 0
	fi

	# Labels do próprio container, pelo mesmo motivo do entrypoint:
	# o roteador do dashboard costuma citar o certresolver real.
	nome="$(traefik_labels "$container" |
		grep -oE '^traefik\.http\.routers\.[A-Za-z0-9_-]+\.tls\.certresolver=[A-Za-z0-9_-]+' |
		head -1 |
		sed -E 's/.*certresolver=//')"

	if [[ -n "$nome" ]]; then
		PA_TRAEFIK_CERTRESOLVER="$nome"
		PA_TRAEFIK_CERTRESOLVER_ORIGEM="label do container do Traefik"
		return 0
	fi

	local config
	if config="$(traefik_config_estatica "$container")"; then
		nome="$(printf '%s\n' "$config" |
			awk '
				/^[[:space:]]*certificates[rR]esolvers:/ { dentro = 1; next }
				dentro && /^[^[:space:]]/                { dentro = 0 }
				dentro && /^[[:space:]]{2}[A-Za-z0-9_-]+:/ {
					gsub(/[[:space:]:]/, "", $0); print $0; exit
				}
			')"

		if [[ -n "$nome" ]]; then
			PA_TRAEFIK_CERTRESOLVER="$nome"
			PA_TRAEFIK_CERTRESOLVER_ORIGEM="arquivo estático dentro do container"
			return 0
		fi
	fi

	PA_TRAEFIK_CERTRESOLVER=""
	PA_TRAEFIK_CERTRESOLVER_ORIGEM="não encontrado"
	return 1
}

# ------------------------------------------------------------
# Rede
# ------------------------------------------------------------

# traefik_detectar_rede <container>
#
# Precedência: --providers.docker.network ganha de tudo, porque é
# a rede que o Traefik de fato usa para falar com os containers,
# mesmo estando ligado a várias.
traefik_detectar_rede() {
	local container="$1"

	local forcada
	forcada="$(traefik_argumentos "$container" |
		grep -oE -- '--providers\.docker\.network=[A-Za-z0-9_.-]+' |
		head -1 |
		sed -E 's/.*network=//')"

	if [[ -n "$forcada" ]]; then
		PA_TRAEFIK_NETWORK="$forcada"
		PA_TRAEFIK_NETWORK_ORIGEM="--providers.docker.network"
		return 0
	fi

	local modo
	modo="$(traefik_inspect "$container" '{{.HostConfig.NetworkMode}}')"

	if [[ "$modo" == "host" ]]; then
		PA_TRAEFIK_HOST_MODE=1
		PA_TRAEFIK_NETWORK=""
		PA_TRAEFIK_NETWORK_ORIGEM="container em network_mode: host"
		return 1
	fi

	local candidatas=()
	local rede
	# shellcheck disable=SC2016
	# $k é do template do Go, não do shell.
	while IFS= read -r rede; do
		[[ -z "$rede" ]] && continue

		local ignorar=0
		local reservada
		for reservada in "${PA_TRAEFIK_REDES_IGNORADAS[@]}"; do
			[[ "$rede" == "$reservada" ]] && ignorar=1
		done

		[[ "$ignorar" -eq 0 ]] && candidatas+=("$rede")
	done < <(traefik_inspect "$container" '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}
{{end}}')

	if [[ "${#candidatas[@]}" -eq 0 ]]; then
		return 1
	fi

	ui_escolher PA_TRAEFIK_NETWORK \
		"O Traefik está em mais de uma rede. Qual liga ao Mautic?" \
		"${candidatas[@]}"

	PA_TRAEFIK_NETWORK_ORIGEM="redes do container"
	return 0
}

# ------------------------------------------------------------
# Orquestração da detecção
# ------------------------------------------------------------

# traefik_detectar
#
# Preenche o que conseguir e devolve 1 quando não há Traefik.
# O que não for encontrado fica vazio, para o orquestrador
# perguntar com o padrão apenas como sugestão.
traefik_detectar() {
	if ! traefik_detectar_container; then
		return 1
	fi

	ui_ok "Traefik encontrado: ${PA_TRAEFIK_CONTAINER}"

	traefik_detectar_entrypoint "$PA_TRAEFIK_CONTAINER" || {
		PA_TRAEFIK_ENTRYPOINT=""
		PA_TRAEFIK_ENTRYPOINT_ORIGEM="não encontrado"
	}

	traefik_detectar_certresolver "$PA_TRAEFIK_CONTAINER" || true

	traefik_detectar_rede "$PA_TRAEFIK_CONTAINER" || true

	return 0
}

# traefik_mostrar_deteccao
#
# Tabela com valor e origem de cada item. A origem existe porque
# "detectado" sozinho não permite julgar: um valor vindo das
# flags de CLI merece mais confiança que um chute em cima do
# padrão.
traefik_mostrar_deteccao() {
	ui_secao "O que encontrei no Traefik desta máquina"

	printf '  %-16s %-24s %s\n' "ITEM" "VALOR" "ORIGEM"
	printf '  %-16s %-24s %s\n' \
		"rede" \
		"${PA_TRAEFIK_NETWORK:-<não encontrada>}" \
		"$PA_TRAEFIK_NETWORK_ORIGEM"
	printf '  %-16s %-24s %s\n' \
		"entrypoint" \
		"${PA_TRAEFIK_ENTRYPOINT:-<não encontrado>}" \
		"$PA_TRAEFIK_ENTRYPOINT_ORIGEM"
	printf '  %-16s %-24s %s\n' \
		"certresolver" \
		"${PA_TRAEFIK_CERTRESOLVER:-<nenhum>}" \
		"$PA_TRAEFIK_CERTRESOLVER_ORIGEM"

	ui_vazio

	if [[ "$PA_TRAEFIK_HOST_MODE" -eq 1 ]]; then
		ui_aviso "O Traefik está em network_mode: host."
		ui_detalhe "O label traefik.docker.network deixa de fazer sentido,"
		ui_detalhe "e o Mautic precisa ser alcançado por outro caminho."
		ui_detalhe "Informe a rede à mão com --traefik-network= se souber."
		ui_vazio
	fi

	if [[ -z "$PA_TRAEFIK_CERTRESOLVER" ]]; then
		ui_aviso "Nenhum certresolver encontrado."
		ui_detalhe "É o normal em quem termina o SSL fora da VPS, no"
		ui_detalhe "Cloudflare por exemplo. O label de certresolver será"
		ui_detalhe "omitido, e não preenchido com um palpite."
		ui_detalhe "Se estiver errado, use --traefik-certresolver=."
		ui_vazio
	fi
}

# ============================================================
# lib/traefik_instalar.sh
# ============================================================

# shellcheck shell=bash
#
# ============================================================
# lib/traefik_instalar.sh
# Instalação do Traefik.
#
# Depende de lib/ui.sh, lib/portas.sh e lib/docker_instalar.sh.
#
# Só entra no instalador de base, pelo mesmo motivo do
# docker_instalar.sh: o proxy é infraestrutura compartilhada, e
# quem instala infraestrutura é a base. O instalador de ferramenta
# só detecta, para descobrir os nomes de rede, entrypoint e
# certresolver que precisa citar nos labels.
# ============================================================
# ------------------------------------------------------------
# Constantes
# ------------------------------------------------------------

# Versão fixa da linha v3, nunca `latest`. Conferida na API do
# Docker Hub em 2026-09-01 e validada em VPS.
PA_TRAEFIK_VERSAO="v3.7.12"

PA_TRAEFIK_DIR="/opt/playahead/traefik"
PA_TRAEFIK_REDE="traefik_public"

# ------------------------------------------------------------
# Instalação
# ------------------------------------------------------------

# traefik_gerar_compose <caminho> <email_acme>
#
# Decisões que este compose carrega, e o motivo de cada uma:
#
#   exposedByDefault=false  sem isso todo container da máquina
#                           vira roteador por acidente
#   redirect no entrypoint  um middleware precisaria ser citado
#                           por cada roteador; no entrypoint vale
#                           para tudo e o .env do Mautic não
#                           precisa saber que existe
#   httpchallenge           é o desafio que funciona quando o DNS
#                           acabou de ser apontado e ainda não há
#                           certificado nenhum
#   socket :ro              o Traefik só precisa ler
traefik_gerar_compose() {
	local caminho="$1"

	cat >"$caminho" <<COMPOSE
services:
  traefik:
    image: traefik:${PA_TRAEFIK_VERSAO}
    restart: unless-stopped
    command:
      - --providers.docker=true
      - --providers.docker.exposedByDefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.letsencrypt.acme.email=\${ACME_EMAIL}
      - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.letsencrypt.acme.httpchallenge=true
      - --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik_letsencrypt:/letsencrypt
    networks:
      - ${PA_TRAEFIK_REDE}

volumes:
  traefik_letsencrypt:
    name: playahead_traefik_letsencrypt

networks:
  ${PA_TRAEFIK_REDE}:
    external: true
    name: ${PA_TRAEFIK_REDE}
COMPOSE
}

# shellcheck disable=SC2034
# traefik_instalar <email_acme>
#
# Idempotente pela regra de nada destrutivo: encontrando um
# compose nosso já no lugar, não sobrescreve. O e-mail do ACME
# vive no .env, com umask 077.
traefik_instalar() {
	local email_acme="$1"

	ui_passo "Instalando o Traefik ${PA_TRAEFIK_VERSAO}"

	docker_criar_rede "$PA_TRAEFIK_REDE"

	mkdir -p "$PA_TRAEFIK_DIR"

	local compose="${PA_TRAEFIK_DIR}/docker-compose.yml"
	local env_file="${PA_TRAEFIK_DIR}/.env"

	if [[ -f "$compose" ]]; then
		ui_ok "Compose do Traefik já existe em ${PA_TRAEFIK_DIR}"
		ui_detalhe "Não sobrescrito, conforme a regra de nada destrutivo."
	else
		traefik_gerar_compose "$compose"
		ui_ok "Compose gravado em ${compose}"
	fi

	if [[ -f "$env_file" ]]; then
		ui_ok ".env do Traefik já existe"
	else
		local mascara_antiga
		mascara_antiga="$(umask)"
		umask 077
		printf 'ACME_EMAIL=%s\n' "$email_acme" >"$env_file"
		umask "$mascara_antiga"
		ui_ok ".env gravado, com o e-mail do Let's Encrypt"
	fi

	ui_info "Subindo o Traefik"
	if ! (cd "$PA_TRAEFIK_DIR" && docker compose up -d >/dev/null 2>&1); then
		ui_fatal \
			"Falha ao subir o Traefik." \
			"Rode à mão para ver o erro:" \
			"" \
			"    cd ${PA_TRAEFIK_DIR} && docker compose up -d"
	fi

	ui_aguardar_ate "Aguardando o Traefik ocupar as portas 80 e 443" 90 \
		traefik_portas_ocupadas ||
		ui_fatal \
			"O Traefik subiu mas não está ouvindo em 80 e 443." \
			"Veja o log:" \
			"" \
			"    cd ${PA_TRAEFIK_DIR} && docker compose logs traefik"

	ui_ok "Traefik ${PA_TRAEFIK_VERSAO} no ar"

	# As seis abaixo são declaradas em lib/traefik.sh e lidas por
	# traefik_mostrar_deteccao. A diretiva está no topo da função,
	# porque o shellcheck não enxerga uso entre arquivos.
	PA_TRAEFIK_NETWORK="$PA_TRAEFIK_REDE"
	PA_TRAEFIK_NETWORK_ORIGEM="instalado por este script"
	PA_TRAEFIK_ENTRYPOINT="websecure"
	PA_TRAEFIK_ENTRYPOINT_ORIGEM="instalado por este script"
	PA_TRAEFIK_CERTRESOLVER="letsencrypt"
	PA_TRAEFIK_CERTRESOLVER_ORIGEM="instalado por este script"
}

# traefik_portas_ocupadas
#
# Usa a cadeia de lib/portas.sh, para não reintroduzir a
# dependência de `ss` que aquele módulo já resolveu.
traefik_portas_ocupadas() {
	local ferramenta
	ferramenta="$(portas_ferramenta)"

	[[ -n "$ferramenta" ]] || return 1

	portas_ocupada 80 "$ferramenta" &&
		portas_ocupada 443 "$ferramenta"
}

# ============================================================

# ============================================================
# lib/cenario.sh
# ============================================================

# shellcheck shell=bash
#
# ============================================================
# lib/cenario.sh
# Classificação do estado da máquina.
#
# Depende de lib/ui.sh, lib/docker.sh e lib/traefik.sh.
#
# Compartilhado pelos dois instaladores, e é a razão de existir
# como arquivo próprio: a tabela de cinco estados é o trecho que
# mais sofreria se fosse duplicada nos dois orquestradores.
#
# Este arquivo **classifica, não decide**. Ele diz em que estado a
# máquina está; o que fazer com isso é política de cada
# orquestrador. Por isso a checagem de portas 80 e 443 não está
# aqui: ela só importa para quem vai subir um proxy, e isso é
# assunto da base.
# ============================================================

# ------------------------------------------------------------
# Estado
# ------------------------------------------------------------

# Preenchidas por cenario_classificar. Não há variável com o
# "número do cenário": ninguém a lia, e estes três sinalizadores
# carregam a mesma informação sem precisar de tradução.
PA_TEM_DOCKER=0
PA_TEM_COMPOSE=0
PA_TEM_TRAEFIK=0

# ------------------------------------------------------------
# Classificação
# ------------------------------------------------------------

# cenario_classificar
#
# A tabela de estados do CLAUDE.md, reduzida ao que dá para
# afirmar só olhando Docker e Traefik:
#
#   nada instalado                    -> cenário 1
#   Docker presente, sem proxy        -> cenário 1.5
#   Docker e Traefik presentes        -> cenário 2
#
# O nome do cenário fica na mensagem de tela de cada orquestrador,
# em palavras, e não numa variável: era só rótulo.
#
# As duas linhas que abortam na tabela — portas ocupadas sem
# proxy — dependem do estado das portas, e quem as trata é o
# instalador de base, porque só ele tem motivo para querer as
# portas livres.
#
# Swarm ativo para aqui, em qualquer estado.
cenario_classificar() {
	docker_checar_swarm

	docker_presente && PA_TEM_DOCKER=1
	[[ "$PA_TEM_DOCKER" -eq 1 ]] && docker_compose_presente && PA_TEM_COMPOSE=1

	if [[ "$PA_TEM_DOCKER" -eq 1 ]] && traefik_detectar; then
		PA_TEM_TRAEFIK=1
	fi

}

# cenario_base_completa
#
# Verdadeiro quando a base já está inteira: Docker, plugin do
# Compose e um Traefik em execução.
#
# É o que um instalador de ferramenta precisa saber. Para ele não
# existem cinco estados, existem dois: a base está pronta, ou
# falta rodar a base.
cenario_base_completa() {
	[[ "$PA_TEM_DOCKER" -eq 1 ]] &&
		[[ "$PA_TEM_COMPOSE" -eq 1 ]] &&
		[[ "$PA_TEM_TRAEFIK" -eq 1 ]]
}

# cenario_faltando
#
# Ecoa, em texto, o que falta da base. Serve para a mensagem que
# manda a pessoa rodar o instalador de base: dizer "falta a base"
# é menos útil que dizer o que exatamente não está lá.
cenario_faltando() {
	local faltando=()

	[[ "$PA_TEM_DOCKER" -eq 1 ]] || faltando+=("Docker")
	[[ "$PA_TEM_COMPOSE" -eq 1 ]] || faltando+=("plugin do Docker Compose")
	[[ "$PA_TEM_TRAEFIK" -eq 1 ]] || faltando+=("Traefik")

	if [[ "${#faltando[@]}" -eq 0 ]]; then
		return 1
	fi

	local texto
	texto="$(printf '%s, ' "${faltando[@]}")"
	printf '%s\n' "${texto%, }"
}

# ============================================================
# lib/portainer.sh
# ============================================================

# shellcheck shell=bash
#
# ============================================================
# lib/portainer.sh
# Instalação opcional do Portainer, sempre por último.
#
# Depende de lib/ui.sh, lib/checks.sh, lib/docker.sh e das
# variáveis de rede preenchidas por lib/traefik.sh.
#
# REGRA QUE VALE PARA O ARQUIVO TODO: nenhuma função aqui chama
# ui_fatal. O Portainer roda depois de o Mautic estar de pé, e a
# decisão de projeto é que uma falha aqui seja aviso, não
# desastre — a pessoa termina com o Mautic funcionando de
# qualquer jeito. Toda função devolve status; quem decide o que
# fazer é o main.sh.
#
# NÃO VALIDADO EM VPS. O módulo foi escrito depois de a máquina
# de teste ser destruída. A instalação do Mautic e a detecção do
# Traefik têm teste; isto ainda não.
# ============================================================

# ------------------------------------------------------------
# Constantes
# ------------------------------------------------------------

# Versão fixa, nunca `latest`, pela mesma razão do Traefik.
#
# 2.45.0 é a LTS em 2026-09-12. Conferido comparando o digest da
# tag `lts` com o da tag numerada, e não assumido pelo número:
# a linha 2.39.x recebe patches e parece LTS, mas o digest da
# `lts` bate com a 2.45.0.
PA_PORTAINER_VERSAO="2.45.0"

PA_PORTAINER_DIR="/opt/playahead/portainer"

# Preenchida na instalação, lida pelo bloco final.
PA_PORTAINER_INSTALADO=0

# ------------------------------------------------------------
# Detecção
# ------------------------------------------------------------

# portainer_ja_existe
#
# Container em execução cuja imagem casa com "portainer".
# Encontrando um, não mexe: pode ser o Portainer de outra pessoa,
# gerenciando containers que não são nossos.
portainer_ja_existe() {
	docker ps --format '{{.Image}}' 2>/dev/null |
		grep -qi 'portainer'
}

# ------------------------------------------------------------
# Compose
# ------------------------------------------------------------

# portainer_gerar_compose <caminho>
#
# O socket do Docker vai montado para LEITURA E ESCRITA, ao
# contrário do Traefik, que recebe `:ro`. Não há como contornar:
# o Portainer existe para criar, parar e remover containers.
#
# A consequência precisa ficar dita em voz alta, porque não é
# óbvia para quem está começando: quem entra no Portainer tem,
# na prática, root nesta máquina. É por isso que a senha de
# admin precisa ser definida na primeira visita, e é por isso
# que o Portainer não entra no fluxo principal do instalador.
portainer_gerar_compose() {
	local caminho="$1"

	local rede="${PA_TRAEFIK_NETWORK:-traefik_public}"
	local entrypoint="${PA_TRAEFIK_ENTRYPOINT:-websecure}"

	{
		cat <<COMPOSE
# ============================================================
# PLAY AHEAD - Portainer
# Gerado pelo instalador. Versão fixa: ${PA_PORTAINER_VERSAO}
#
# ATENÇÃO: este container monta o socket do Docker com permissão
# de escrita. Quem tem acesso ao Portainer tem controle total
# desta máquina. Use senha forte e não exponha sem necessidade.
# ============================================================

services:

  portainer:
    image: portainer/portainer-ce:${PA_PORTAINER_VERSAO}
    restart: unless-stopped

    command: -H unix:///var/run/docker.sock

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - playahead_portainer_data:/data

    networks:
      - proxy

    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.playahead-portainer.rule=Host(\`${PA_PORTAINER_DOMINIO}\`)"
      - "traefik.http.routers.playahead-portainer.entrypoints=${entrypoint}"
      - "traefik.http.routers.playahead-portainer.tls=true"
COMPOSE

		# O certresolver é omitido quando não existe, e não
		# preenchido com palpite. Mesma regra do Mautic: quem
		# termina TLS no Cloudflare não tem resolver, e um nome
		# inventado produz roteador que não sobe.
		if [[ -n "${PA_TRAEFIK_CERTRESOLVER:-}" ]]; then
			printf '      - "traefik.http.routers.playahead-portainer.tls.certresolver=%s"\n' \
				"$PA_TRAEFIK_CERTRESOLVER"
		fi

		cat <<COMPOSE
      - "traefik.http.services.playahead-portainer.loadbalancer.server.port=9000"
      - "traefik.docker.network=${rede}"

volumes:
  playahead_portainer_data:
    name: playahead_portainer_data

networks:
  proxy:
    external: true
    name: ${rede}
COMPOSE
	} >"$caminho"
}

# ------------------------------------------------------------
# Instalação
# ------------------------------------------------------------

# portainer_instalar <dominio>
#
# Devolve 0 em sucesso. Qualquer falha devolve não-zero, com
# aviso na tela, e deixa o main.sh seguir para o bloco final.
portainer_instalar() {
	PA_PORTAINER_DOMINIO="$1"

	ui_secao "Portainer"

	if portainer_ja_existe; then
		ui_aviso "Já existe um Portainer em execução nesta máquina."
		ui_detalhe "Não vou mexer nele: pode estar gerenciando containers"
		ui_detalhe "que não são desta instalação."
		return 0
	fi

	# DNS do subdomínio do Portainer. Aqui a checagem AVISA em vez
	# de abortar, ao contrário do domínio do Mautic: o Mautic já
	# está no ar, e derrubar a execução por causa de um DNS
	# opcional seria trocar o certo pelo duvidoso.
	if [[ "$PA_SKIP_DNS" -ne 1 ]] && [[ -n "$PA_IP_PUBLICO" ]]; then
		local resolvidos=()
		mapfile -t resolvidos < <(
			getent ahostsv4 "$PA_PORTAINER_DOMINIO" 2>/dev/null |
				awk '{print $1}' | sort -u
		)

		if [[ "${#resolvidos[@]}" -eq 0 ]]; then
			ui_aviso "${PA_PORTAINER_DOMINIO} ainda não resolve para nenhum IP."
			ui_detalhe "O certificado não será emitido enquanto o DNS não"
			ui_detalhe "apontar para ${PA_IP_PUBLICO}."
			ui_detalhe "O Portainer vai subir, mas o domínio só abre depois."
		elif [[ " ${resolvidos[*]} " != *" ${PA_IP_PUBLICO} "* ]] &&
			! checks_ip_em_cdn "${resolvidos[0]}"; then
			ui_aviso "${PA_PORTAINER_DOMINIO} aponta para outro servidor."
			ui_detalhe "resolve para: ${resolvidos[*]}"
			ui_detalhe "esta VPS é:   ${PA_IP_PUBLICO}"
			ui_detalhe "O Portainer vai subir, mas o domínio não vai abrir."
		fi
	fi

	mkdir -p "$PA_PORTAINER_DIR"

	local compose="${PA_PORTAINER_DIR}/docker-compose.yml"

	if [[ -f "$compose" ]]; then
		ui_ok "Compose do Portainer já existe; mantido como está"
	else
		portainer_gerar_compose "$compose"
		ui_ok "Compose gravado em ${compose}"
	fi

	ui_info "Subindo o Portainer ${PA_PORTAINER_VERSAO}"

	if ! (cd "$PA_PORTAINER_DIR" && docker compose up -d >/dev/null 2>&1); then
		ui_aviso "Falha ao subir o Portainer."
		ui_detalhe "O Mautic não foi afetado e segue no ar."
		ui_detalhe "Para ver o erro:"
		ui_detalhe "cd ${PA_PORTAINER_DIR} && docker compose up -d"
		return 1
	fi

	if ! ui_aguardar_ate "Aguardando o Portainer responder" 90 \
		portainer_respondendo; then
		ui_aviso "O Portainer subiu mas não respondeu no tempo esperado."
		ui_detalhe "Veja: cd ${PA_PORTAINER_DIR} && docker compose logs"
		return 1
	fi

	PA_PORTAINER_INSTALADO=1
	ui_ok "Portainer ${PA_PORTAINER_VERSAO} no ar"

	portainer_verificar_roteamento "$PA_PORTAINER_DOMINIO" || true

	return 0
}

# portainer_respondendo
#
# Pergunta ao próprio container, sem depender do Traefik nem do
# DNS. A imagem do Portainer não traz curl nem wget, então o
# teste é feito de fora, pela rede do Docker: se o container está
# em execução e não reiniciando, o serviço subiu.
portainer_respondendo() {
	local id
	id="$(cd "$PA_PORTAINER_DIR" && docker compose ps -q portainer 2>/dev/null)"
	[[ -n "$id" ]] || return 1

	local estado
	estado="$(docker inspect --format '{{.State.Status}}' "$id" 2>/dev/null)"

	[[ "$estado" == "running" ]]
}

# portainer_verificar_roteamento <dominio>
#
# Mesma verificação anti-404 do Mautic, mas sempre como aviso.
portainer_verificar_roteamento() {
	local dominio="$1"

	local codigo
	codigo="$(curl -sk -o /dev/null -w '%{http_code}' \
		--max-time 15 "https://${dominio}/" 2>/dev/null || true)"

	case "$codigo" in
		200 | 302 | 301 | 307)
			ui_ok "O domínio do Portainer responde ${codigo}"
			return 0
			;;
		404)
			ui_aviso "O Traefik respondeu, mas não roteou para o Portainer."
			ui_detalhe "Confira os nomes em ${PA_PORTAINER_DIR}/docker-compose.yml"
			;;
		*)
			ui_aviso "O domínio do Portainer respondeu ${codigo:-nada}."
			ui_detalhe "Pode ser propagação de DNS ou emissão de certificado."
			;;
	esac

	return 1
}

# ------------------------------------------------------------
# Credenciais e primeira visita
# ------------------------------------------------------------

# portainer_anexar_credenciais <arquivo>
#
# Acrescenta o bloco do Portainer no mesmo credenciais.txt do
# Mautic, em vez de criar um segundo arquivo. Um arquivo só, com
# tudo da instalação, é mais fácil de achar meses depois do que
# dois arquivos em pastas diferentes.
portainer_anexar_credenciais() {
	local arquivo="$1"

	[[ "$PA_PORTAINER_INSTALADO" -eq 1 ]] || return 0
	[[ -f "$arquivo" ]] || return 0

	{
		printf '\n'
		printf 'PORTAINER\n'
		printf '  URL:   https://%s\n' "$PA_PORTAINER_DOMINIO"
		printf '  senha: definida por você na primeira visita\n'
		printf '  pasta: %s\n' "$PA_PORTAINER_DIR"
	} >>"$arquivo"

	chmod 600 "$arquivo"
}

# portainer_aviso_primeira_visita
#
# O Portainer fecha a criação do usuário administrador se ninguém
# a fizer poucos minutos depois de o container subir, e então só
# volta a aceitar com um restart do container. Numa instalação
# que a pessoa deixa rodando e vai tomar café, isso vira um
# "não funcionou" que não tem nada de erro.
#
# Por isso o aviso é explícito e traz o comando de recuperação.
portainer_aviso_primeira_visita() {
	[[ "$PA_PORTAINER_INSTALADO" -eq 1 ]] || return 0

	ui_vazio
	ui_info "PORTAINER: abra agora e defina a senha."
	ui_detalhe "https://${PA_PORTAINER_DOMINIO}"
	ui_vazio
	ui_info "O Portainer encerra a criação do administrador poucos"
	ui_info "minutos depois de subir. Passando desse prazo, ele só"
	ui_info "volta a aceitar com um restart:"
	ui_detalhe "cd ${PA_PORTAINER_DIR} && docker compose restart"
	ui_vazio
	ui_info "Quem entra no Portainer controla todos os containers"
	ui_info "desta máquina. Use uma senha forte."
}

# ============================================================
# lib/base_main.sh
# ============================================================

# shellcheck shell=bash
#
# ============================================================
# lib/base_main.sh
# Orquestrador do instalador de base.
#
# Depende de todas as libs de base. No dist/base.sh gerado pelo
# build.sh, este é o último trecho, e a chamada a `main "$@"` fica
# no rodapé do arquivo.
#
# A base entrega a infraestrutura que os instaladores de
# ferramenta compartilham: swap, Docker, Compose, a rede do proxy
# e o Traefik. O Portainer entra atrás de flag, porque exige
# subdomínio próprio.
#
# Nenhum instalador de ferramenta chama este script. Faltando a
# base, a ferramenta diz o que falta, mostra o comando e encerra —
# decisão de projeto: um script que a pessoa acabou de ler não vai
# buscar e executar outro por conta própria.
# ============================================================

# ------------------------------------------------------------
# Versão
#
# Independente da versão dos instaladores de ferramenta: cada um
# versiona por conta própria, e a tag leva o prefixo do nome.
# ------------------------------------------------------------

PA_VERSAO="0.1.0"
PA_BUILD="2026-09-12T19:47:59Z"
PA_FONTE="https://github.com/play-ahead/playahead-installer"
PA_FERRAMENTA="Base: Docker, Traefik e Portainer"

# ------------------------------------------------------------
# Respostas e flags
# ------------------------------------------------------------

PA_EMAIL_ACME=""
PA_PORTAINER=0
PA_PORTAINER_DOMINIO=""
PA_SKIP_DNS=0
PA_NO_SWAP=0
PA_NAO_INTERATIVO=0

# ------------------------------------------------------------
# Ajuda e versão
# ------------------------------------------------------------

main_versao() {
	printf 'Play Ahead Installer - %s\n' "$PA_FERRAMENTA"
	printf 'Versão: %s\n' "$PA_VERSAO"
	printf 'Build:  %s\n' "$PA_BUILD"
	printf 'Fonte:  %s\n' "$PA_FONTE"
}

main_ajuda() {
	cat <<'AJUDA'
Play Ahead Installer - Base

Instala a infraestrutura que os instaladores de ferramenta da Play
Ahead compartilham: swap, Docker, Docker Compose, a rede do proxy e
o Traefik com certificado SSL automático. O Portainer é opcional.

Rode isto uma vez por VPS. Depois, cada ferramenta (Mautic 7,
Chatwoot, Typebot) tem o seu próprio instalador e reaproveita esta
base em vez de recriá-la.

USO
    sudo bash base.sh [opções]

OPÇÕES
    --acme-email=EMAIL           e-mail usado no Let's Encrypt
    --portainer                  instala o Portainer também
    --portainer-domain=DOMINIO   subdomínio do Portainer
    --skip-dns-check             pula a validação de DNS
    --no-swap                    não cria arquivo de swap
    --yes                        não interativo, sem nenhuma pergunta
    --help                       mostra esta ajuda
    --version                    mostra a versão e a data do build

EXEMPLOS
    sudo bash base.sh

    sudo bash base.sh --acme-email=voce@exemplo.com.br --yes

    sudo bash base.sh --portainer \
        --portainer-domain=painel.exemplo.com.br

DOCUMENTAÇÃO
    https://github.com/play-ahead/playahead-installer
AJUDA
}

# ------------------------------------------------------------
# Parse das flags
# ------------------------------------------------------------

main_parse_flags() {
	local arg

	for arg in "$@"; do
		case "$arg" in
			--acme-email=*) PA_EMAIL_ACME="${arg#*=}" ;;
			--portainer) PA_PORTAINER=1 ;;
			--portainer-domain=*)
				PA_PORTAINER_DOMINIO="${arg#*=}"
				PA_PORTAINER=1
				;;
			--skip-dns-check) PA_SKIP_DNS=1 ;;
			--no-swap) PA_NO_SWAP=1 ;;
			--yes | -y) PA_NAO_INTERATIVO=1 ;;
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

	return 0
}

# ------------------------------------------------------------
# Detecção e checagens dependentes do estado
# ------------------------------------------------------------

base_detectar() {
	ui_secao "Descobrindo a situação desta máquina"

	cenario_classificar

	if [[ "$PA_TEM_TRAEFIK" -eq 1 ]]; then
		ui_ok "Já existe um proxy Traefik nesta máquina"
		ui_detalhe "Ele será reaproveitado; nada da configuração dele será tocado."
		traefik_mostrar_deteccao
		return 0
	fi

	# Sem proxy, as portas 80 e 443 precisam estar livres. Quem as
	# ocupa é servidor web instalado direto no sistema, e o
	# instalador não desliga serviço de ninguém.
	#
	# É aqui que moram as duas linhas da tabela de estados que
	# abortam, e é por isso que a checagem de portas não vive em
	# cenario.sh: ela só importa para quem vai subir um proxy.
	portas_livres "$([[ "$PA_TEM_DOCKER" -eq 0 ]] && printf 1 || printf 0)"

	if [[ "$PA_TEM_DOCKER" -eq 1 ]]; then
		ui_ok "Docker presente, sem proxy"
		ui_detalhe "Docker será reaproveitado; Traefik será instalado."
	else
		ui_ok "Máquina limpa"
		ui_detalhe "Docker, Compose e Traefik serão instalados."
	fi
}

# ------------------------------------------------------------
# Perguntas
#
# Todas antes de qualquer alteração na máquina, como o resto do
# projeto. A base é dona da própria conversa quando roda sozinha,
# e com --yes não pergunta nada.
# ------------------------------------------------------------

base_perguntar() {
	local pergunta_acme=0
	local pergunta_portainer=0

	# O e-mail do ACME só é necessário quando este script vai
	# instalar o Traefik. Havendo proxy, quem emite certificado é
	# ele, com o e-mail que já tem.
	[[ "$PA_TEM_TRAEFIK" -eq 0 ]] && [[ -z "$PA_EMAIL_ACME" ]] &&
		pergunta_acme=1
	[[ "$PA_PORTAINER" -eq 1 ]] && [[ -z "$PA_PORTAINER_DOMINIO" ]] &&
		pergunta_portainer=1

	if [[ "$pergunta_acme" -eq 0 ]] && [[ "$pergunta_portainer" -eq 0 ]]; then
		return 0
	fi

	ui_secao "Algumas perguntas antes de começar"
	ui_info "Depois daqui a instalação corre sozinha até o fim."

	if [[ "$pergunta_acme" -eq 1 ]]; then
		ui_vazio
		ui_info "O Let's Encrypt pede um e-mail para avisar sobre a"
		ui_info "renovação do certificado. Ele vai para a Let's Encrypt,"
		ui_info "não para a Play Ahead."
		ui_perguntar PA_EMAIL_ACME \
			"E-mail para o certificado SSL" \
			"" checks_validar_email
	fi

	if [[ "$pergunta_portainer" -eq 1 ]]; then
		ui_vazio
		ui_info "O Portainer precisa de um subdomínio próprio, com DNS"
		ui_info "apontando para esta VPS."
		ui_perguntar PA_PORTAINER_DOMINIO \
			"Subdomínio do Portainer (ex: painel.suaempresa.com.br)" \
			"" checks_validar_dominio
	fi
}

# ------------------------------------------------------------
# Validação
# ------------------------------------------------------------

base_validar() {
	[[ "$PA_PORTAINER" -eq 1 ]] || return 0
	[[ "$PA_SKIP_DNS" -eq 0 ]] || return 0

	ui_secao "Conferindo o DNS do Portainer"
	checks_ip_publico || true

	# Avisa em vez de abortar: o Portainer é opcional, e o resto da
	# base não depende do DNS dele.
	if [[ -z "$PA_IP_PUBLICO" ]]; then
		ui_aviso "Não consegui descobrir o IP desta máquina; seguindo."
		return 0
	fi

	local resolvidos=()
	mapfile -t resolvidos < <(
		getent ahostsv4 "$PA_PORTAINER_DOMINIO" 2>/dev/null |
			awk '{print $1}' | sort -u
	)

	if [[ "${#resolvidos[@]}" -eq 0 ]]; then
		ui_aviso "${PA_PORTAINER_DOMINIO} ainda não resolve para nenhum IP."
		ui_detalhe "O Portainer vai subir, mas o domínio só abre depois de"
		ui_detalhe "o DNS apontar para ${PA_IP_PUBLICO}."
		return 0
	fi

	if [[ " ${resolvidos[*]} " == *" ${PA_IP_PUBLICO} "* ]]; then
		ui_ok "DNS de ${PA_PORTAINER_DOMINIO} aponta para esta VPS"
		return 0
	fi

	if checks_ip_em_cdn "${resolvidos[0]}"; then
		ui_aviso "${PA_PORTAINER_DOMINIO} está atrás de CDN; seguindo."
		return 0
	fi

	ui_aviso "${PA_PORTAINER_DOMINIO} aponta para outro servidor."
	ui_detalhe "resolve para: ${resolvidos[*]}"
	ui_detalhe "esta VPS é:   ${PA_IP_PUBLICO}"
	ui_detalhe "O Portainer vai subir, mas o domínio não vai abrir."
}

# ------------------------------------------------------------
# Confirmação
# ------------------------------------------------------------

# base_confirmar
#
# Último ponto antes de escrever qualquer coisa. Diz em palavras o
# que vai ser feito com cada peça, e não só o que foi respondido:
# "reaproveitar" e "instalar" são decisões que a pessoa precisa
# poder conferir antes de o script mexer na máquina.
base_confirmar() {
	local ram acao_swap
	ram="$(sistema_ram_mb)"

	if [[ "$PA_NO_SWAP" -eq 1 ]]; then
		acao_swap="não mexer, por --no-swap"
	elif sistema_tem_swap; then
		acao_swap="já existe, manter"
	elif [[ "$ram" -lt "$PA_RAM_SWAP_MB" ]]; then
		acao_swap="criar 2 GB (RAM de ${ram} MB)"
	else
		acao_swap="dispensado (RAM de ${ram} MB)"
	fi

	# Usa os sinalizadores que cenario_classificar preencheu, e não
	# uma pergunta nova ao Docker: o resumo tem de dizer o que o
	# resto do fluxo decidiu, não fazer a própria leitura.
	local acao_docker="instalar"
	[[ "$PA_TEM_DOCKER" -eq 1 ]] && [[ "$PA_TEM_COMPOSE" -eq 1 ]] &&
		acao_docker="reaproveitar $(docker_versao)"

	local acao_traefik="instalar ${PA_TRAEFIK_VERSAO}"
	[[ "$PA_TEM_TRAEFIK" -eq 1 ]] &&
		acao_traefik="reaproveitar o que já está no ar"

	local -a itens=(
		"Swap" "$acao_swap"
		"Docker e Compose" "$acao_docker"
		"Traefik" "$acao_traefik"
	)

	[[ "$PA_TEM_TRAEFIK" -eq 0 ]] &&
		itens+=("E-mail do SSL" "$PA_EMAIL_ACME")

	if [[ "$PA_PORTAINER" -eq 1 ]]; then
		itens+=("Portainer" "https://${PA_PORTAINER_DOMINIO}")
	else
		itens+=("Portainer" "não instalar (use --portainer)")
	fi

	ui_resumo "Confira antes de começar" "${itens[@]}"
	ui_confirmar_resumo
}

# ------------------------------------------------------------
# Instalação
# ------------------------------------------------------------

base_instalar() {
	ui_secao "Preparando a máquina"

	sistema_criar_swap "$PA_NO_SWAP"
	docker_garantir

	if [[ "$PA_TEM_TRAEFIK" -eq 1 ]]; then
		ui_ok "Traefik já existente mantido como está"
		return 0
	fi

	traefik_instalar "$PA_EMAIL_ACME"
}

# ------------------------------------------------------------
# Bloco final
# ------------------------------------------------------------

base_bloco_final() {
	ui_vazio
	ui_secao "Base pronta"

	ui_info "A infraestrutura compartilhada está no ar:"
	ui_vazio
	ui_info "Docker:       $(docker_versao)"
	ui_info "Compose:      $(docker_compose_versao)"
	ui_info "Rede do proxy: ${PA_TRAEFIK_NETWORK:-${PA_TRAEFIK_REDE}}"
	ui_info "Entrypoint:   ${PA_TRAEFIK_ENTRYPOINT:-websecure}"
	ui_info "Certresolver: ${PA_TRAEFIK_CERTRESOLVER:-<nenhum>}"

	if [[ -n "$PA_SWAP_CRIADO" ]]; then
		ui_vazio
		ui_info "Um arquivo de swap de 2 GB foi criado em ${PA_SWAP_CRIADO}"
		ui_info "porque esta máquina tem pouca memória."
	fi

	portainer_aviso_primeira_visita

	ui_vazio
	ui_info "Agora instale as ferramentas que quiser. Cada uma tem o"
	ui_info "seu próprio instalador e reaproveita esta base:"
	ui_detalhe "Mautic 7:  https://get.playahead.com.br/mautic7"
	ui_vazio
	ui_separador
	ui_info "Quer receber avisos de novas versões, correções e conteúdos"
	ui_info "da Play Ahead sobre automação de marketing?"
	ui_detalhe "https://playahead.com.br/avisos"
	ui_separador
	ui_vazio
}

# ------------------------------------------------------------
# main
# ------------------------------------------------------------

main() {
	main_parse_flags "$@"

	ui_init "$PA_NAO_INTERATIVO"
	ui_cabecalho

	checks_sistema
	base_detectar
	base_perguntar
	base_validar
	base_confirmar
	base_instalar

	if [[ "$PA_PORTAINER" -eq 1 ]]; then
		portainer_instalar "$PA_PORTAINER_DOMINIO" || true
	fi

	base_bloco_final
}

# ============================================================
# Ponto de entrada
# ============================================================

main "$@"
