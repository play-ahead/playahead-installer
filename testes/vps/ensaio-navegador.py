#!/usr/bin/env python3
# testes/vps/ensaio-navegador.py
#
# Abre o Mautic e o Portainer num navegador de verdade (Chromium, sem
# janela, pelo Playwright), entra com o que está nos credenciais.txt
# desta máquina e tira uma foto de cada tela. É a parte do teste final
# que o curl não faz: o formulário de login funcionando, o painel
# abrindo depois dele, e o idioma das telas.
#
# Roda NA VPS de teste, como root, depois de instalar a base e o Mautic:
#
#     python3 -m venv /root/pw
#     /root/pw/bin/pip install playwright
#     /root/pw/bin/playwright install --with-deps chromium
#     /root/pw/bin/python ensaio-navegador.py --saida /root/ensaio
#
# Os domínios e as senhas são lidos dos credenciais.txt. A senha nunca
# é impressa: o resultado diz só se o login entrou.
#
# Com domínios de teste (.test, no /etc/hosts), o certificado é o
# padrão do Traefik, e por isso o navegador ignora o erro de
# certificado. Com domínio de verdade, passe --certificado-valido para
# o navegador recusar certificado inválido, como o de qualquer pessoa.
#
# Com --sem-login o roteiro só abre as telas de login e tira a foto,
# sem digitar senha nenhuma: serve para conferir, num domínio de
# verdade, que a página abre com certificado válido e sem laço de
# redirecionamento.

import argparse
import json
import os
import re
import sys

from playwright.sync_api import sync_playwright


def campo(texto, rotulo):
    """O valor de uma linha "rótulo: valor" de um credenciais.txt."""
    m = re.search(r"^\s*%s:\s*(\S.*?)\s*$" % re.escape(rotulo), texto, re.M | re.I)
    return m.group(1) if m else ""


def ler(caminho):
    with open(caminho, encoding="utf-8") as f:
        return f.read()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--saida", required=True, help="pasta para as fotos e o resultado")
    p.add_argument("--certificado-valido", action="store_true")
    p.add_argument("--sem-portainer", action="store_true")
    p.add_argument("--sem-login", action="store_true")
    a = p.parse_args()

    os.makedirs(a.saida, exist_ok=True)

    mautic = ler("/opt/playahead/mautic/credenciais.txt")
    url_mautic = campo(mautic, "URL")
    email = campo(mautic, "e-mail")
    senha_mautic = campo(mautic, "senha")

    resultado = {"mautic": {"url": url_mautic}, "portainer": {}}

    with sync_playwright() as pw:
        navegador = pw.chromium.launch()
        contexto = navegador.new_context(
            ignore_https_errors=not a.certificado_valido,
            viewport={"width": 1280, "height": 800},
            locale="pt-BR",
        )
        pagina = contexto.new_page()

        # ---------------- Mautic ----------------
        m = resultado["mautic"]
        pagina.goto(url_mautic + "/", wait_until="networkidle", timeout=120000)
        m["tela_de_login"] = pagina.url
        m["formulario_de_login"] = pagina.locator("input[name=_username]").count() == 1
        pagina.screenshot(path=os.path.join(a.saida, "mautic-1-login.png"))

        if a.sem_login:
            m["titulo"] = pagina.title()
            if not a.sem_portainer and os.path.exists("/opt/playahead/portainer/credenciais.txt"):
                url_portainer = campo(ler("/opt/playahead/portainer/credenciais.txt"), "URL")
                q = resultado["portainer"]
                q["url"] = url_portainer
                pagina.goto(url_portainer + "/", wait_until="networkidle", timeout=120000)
                q["tela_inicial"] = pagina.url
                q["pediu_token_de_setup"] = "setup token" in pagina.inner_text("body").lower()
                q["campo_de_usuario"] = pagina.locator("#username").count() == 1
                pagina.screenshot(path=os.path.join(a.saida, "portainer-1-login.png"))
            navegador.close()
            with open(os.path.join(a.saida, "resultado.json"), "w", encoding="utf-8") as f:
                json.dump(resultado, f, ensure_ascii=False, indent=2)
            print(json.dumps(resultado, ensure_ascii=False, indent=2))
            sys.exit(0 if m["formulario_de_login"] else 1)

        pagina.fill("input[name=_username]", email)
        pagina.fill("input[name=_password]", senha_mautic)
        pagina.locator("form button[type=submit]").first.click()
        pagina.wait_for_load_state("networkidle", timeout=120000)

        m["depois_do_login"] = pagina.url
        m["entrou"] = "/s/login" not in pagina.url and "/s/" in pagina.url
        m["idioma_da_pagina"] = pagina.locator("html").get_attribute("lang") or ""
        m["titulo"] = pagina.title()
        texto = pagina.inner_text("body")
        m["palavras_em_portugues"] = [
            w for w in ("Painel", "Contatos", "Campanhas", "Segmentos", "Relatórios", "Configurações")
            if w in texto
        ]
        m["palavras_em_ingles"] = [
            w for w in ("Dashboard", "Contacts", "Campaigns", "Segments", "Reports")
            if re.search(r"\b%s\b" % w, texto)
        ]
        pagina.screenshot(path=os.path.join(a.saida, "mautic-2-painel.png"))

        pagina.goto(url_mautic + "/s/contacts", wait_until="networkidle", timeout=120000)
        m["tela_de_contatos"] = pagina.url
        m["titulo_de_contatos"] = pagina.title()
        pagina.screenshot(path=os.path.join(a.saida, "mautic-3-contatos.png"))

        # ---------------- Portainer ----------------
        if not a.sem_portainer and os.path.exists("/opt/playahead/portainer/credenciais.txt"):
            portainer = ler("/opt/playahead/portainer/credenciais.txt")
            url_portainer = campo(portainer, "URL")
            usuario = campo(portainer, "usuário")
            senha_portainer = campo(portainer, "senha")

            q = resultado["portainer"]
            q["url"] = url_portainer

            pagina = contexto.new_page()
            pagina.goto(url_portainer + "/", wait_until="networkidle", timeout=120000)
            q["tela_inicial"] = pagina.url
            q["pediu_token_de_setup"] = "setup token" in pagina.inner_text("body").lower()
            pagina.screenshot(path=os.path.join(a.saida, "portainer-1-login.png"))

            pagina.fill("#username", usuario)
            pagina.fill("#password", senha_portainer)
            pagina.locator("button[type=submit]").first.click()
            try:
                pagina.wait_for_url(re.compile(r"#!/(home|wizard|endpoints|dashboard)"), timeout=60000)
            except Exception:
                pass
            pagina.wait_for_load_state("networkidle", timeout=60000)

            q["depois_do_login"] = pagina.url
            q["entrou"] = "#!/auth" not in pagina.url and "#!/" in pagina.url
            q["titulo"] = pagina.title()
            pagina.screenshot(path=os.path.join(a.saida, "portainer-2-dentro.png"))

        navegador.close()

    with open(os.path.join(a.saida, "resultado.json"), "w", encoding="utf-8") as f:
        json.dump(resultado, f, ensure_ascii=False, indent=2)

    print(json.dumps(resultado, ensure_ascii=False, indent=2))

    falhou = not resultado["mautic"].get("entrou") or (
        resultado["portainer"] and not resultado["portainer"].get("entrou")
    )
    sys.exit(1 if falhou else 0)


if __name__ == "__main__":
    main()
