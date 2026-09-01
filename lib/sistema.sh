#!/usr/bin/env bash
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
