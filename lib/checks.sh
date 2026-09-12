#!/usr/bin/env bash
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
