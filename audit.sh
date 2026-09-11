#!/bin/bash
# Audyt bezpieczeństwa VPS (Ubuntu) - sprawdza to, co ustawia PROMPT.md.
# Uruchamiany przez agenta na serwerze:  curl -fsSL <url>/audit.sh | ssh HOST "sudo bash -s"

set -uo pipefail

PASS=0; FAIL=0
pass() { echo "  [PASS]  $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL]  $1"; FAIL=$((FAIL + 1)); }
header() { echo; echo "━━━ $1 ━━━"; }

if [[ $EUID -ne 0 ]]; then
  echo "Uruchom jako root (sudo bash audit.sh) - bez tego sshd -T, ufw i fail2ban nie odpowiedzą."
  exit 2
fi

echo "AUDYT BEZPIECZEŃSTWA VPS - $(date '+%Y-%m-%d %H:%M')"
. /etc/os-release 2>/dev/null && echo "System: ${PRETTY_NAME:-nieznany}"

# Ile razy ktoś pukał do SSH w ostatnim tygodniu - żeby było widać, przed czym to wszystko chroni
TRIES=$(journalctl -u ssh -u sshd --since "7 days ago" --no-pager 2>/dev/null | grep -cE "Failed password|Invalid user|authentication failure" || echo 0)
echo "Nieudane próby logowania SSH z ostatnich 7 dni: ${TRIES}"

SSHD=$(sshd -T 2>/dev/null || true)
opt() { echo "$SSHD" | awk -v k="$1" '$1==k {print $2; exit}'; }

header "1. Użytkownik zamiast roota"
SUDO_USERS=$(getent group sudo | cut -d: -f4)
if [[ -n "$SUDO_USERS" ]]; then pass "Użytkownik z sudo istnieje: $SUDO_USERS"; else fail "Brak użytkownika z sudo - logujesz się jako root"; fi

KEYS_OK=false
for d in /home/*/.ssh; do [[ -s "$d/authorized_keys" ]] && KEYS_OK=true && KEYS_WHERE="$d"; done
if $KEYS_OK; then pass "Klucz SSH nowego użytkownika: $KEYS_WHERE/authorized_keys"; else fail "Żaden zwykły użytkownik nie ma klucza SSH"; fi

header "2. SSH"
if [[ -z "$SSHD" ]]; then
  fail "sshd -T nie działa - konfiguracja SSH jest uszkodzona"
else
  [[ "$(opt permitrootlogin)" == "no" ]]        && pass "Root nie może logować się przez SSH"      || fail "Root może logować się przez SSH (permitrootlogin: $(opt permitrootlogin))"
  [[ "$(opt passwordauthentication)" == "no" ]] && pass "Logowanie hasłem wyłączone"              || fail "Logowanie hasłem włączone"
  [[ "$(opt kbdinteractiveauthentication)" == "no" ]] && pass "Logowanie interaktywne wyłączone"  || fail "Logowanie interaktywne (keyboard-interactive) włączone"
  MAX=$(opt maxauthtries); [[ -n "$MAX" && "$MAX" -le 3 ]] && pass "MaxAuthTries: $MAX"         || fail "MaxAuthTries: ${MAX:-6} (ma być 3)"
fi
[[ -f /etc/ssh/sshd_config.d/00-hardening.conf ]] && pass "Plik 00-hardening.conf obecny (wygrywa z cloud-init)" || fail "Brak /etc/ssh/sshd_config.d/00-hardening.conf"

header "3. Zapora (UFW)"
if command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -q "^Status: active"; then
    pass "UFW aktywny"
    ufw status verbose 2>/dev/null | grep -q "^Default: deny (incoming)" && pass "Domyślnie: nic nie wchodzi (deny incoming)" || fail "Domyślna polityka UFW nie blokuje ruchu przychodzącego"
    echo "         otwarte: $(ufw status | awk '/ALLOW/ {print $1}' | sort -u | tr '\n' ' ')"
  else fail "UFW zainstalowany, ale nieaktywny"; fi
else fail "UFW nie zainstalowany"; fi

header "4. Fail2ban"
if command -v fail2ban-client >/dev/null 2>&1; then
  if systemctl is-active --quiet fail2ban; then
    pass "Fail2ban aktywny"
    if fail2ban-client status sshd >/dev/null 2>&1; then
      B=$(fail2ban-client status sshd | awk -F: '/Currently banned/ {gsub(/ /,"",$2); print $2}')
      pass "Jail sshd działa (aktualnie zbanowane: ${B:-0})"
    else fail "Jail sshd nie działa"; fi
    ADMIN_IP=$(grep -E '^ignoreip' /etc/fail2ban/jail.local 2>/dev/null | sed -E 's/^ignoreip\s*=//; s#127\.0\.0\.1(/8)?##g; s/::1//g' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' | head -1)
    [[ -n "$ADMIN_IP" ]] && pass "Adres administratora na liście wyjątków (ignoreip: $ADMIN_IP)" || fail "Brak adresu administratora w ignoreip (jest tylko localhost) - ryzyko samobana"
  else fail "Fail2ban zainstalowany, ale nieaktywny"; fi
else fail "Fail2ban nie zainstalowany"; fi

header "5. Automatyczne aktualizacje"
if dpkg -s unattended-upgrades >/dev/null 2>&1; then
  pass "unattended-upgrades zainstalowany"
  grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null && pass "Auto-instalacja łatek włączona" || fail "Brak /etc/apt/apt.conf.d/20auto-upgrades z Unattended-Upgrade \"1\""
  systemctl is-enabled --quiet apt-daily.timer && systemctl is-enabled --quiet apt-daily-upgrade.timer && pass "Timery apt-daily włączone" || fail "Timery apt-daily wyłączone - łatki nie będą się instalować"
else fail "unattended-upgrades nie zainstalowany"; fi

if command -v docker >/dev/null 2>&1; then
  header "6. Docker - co jest widoczne z internetu (informacja, nie ocena)"
  if ! PS_OUT=$(docker ps --format '{{.Names}}: {{.Ports}}' 2>&1); then
    echo "  [INFO]  Nie udało się odczytać kontenerów (docker ps: ${PS_OUT%%$'\n'*})"
    PS_OUT=""; EXPOSED="__SKIP__"
  else
    # publiczny = każdy adres poza localhost i siecią Tailscale (100.64.0.0/10)
    EXPOSED=$(echo "$PS_OUT" | grep -E '[0-9a-f:.]+:[0-9]+->' | grep -vE '(127\.0\.0\.1|\[::1\]|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+):[0-9]+->' | grep -E ':[0-9]+->' || true)
  fi
  if [[ "$EXPOSED" == "__SKIP__" ]]; then :; elif [[ -z "$EXPOSED" ]]; then echo "  [INFO]  Żaden kontener nie publikuje portu na cały świat"; else echo "  [INFO]  Porty kontenerów otwarte na internet (omijają UFW) - sprawdź, czy każdy ma tak być:"; echo "$EXPOSED" | sed 's/^/          /'; fi
fi

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PASS: $PASS   FAIL: $FAIL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ $FAIL -eq 0 ]] && echo "Podstawowe kontrole: wszystko OK." || echo "Do poprawy: $FAIL."
# Celowo zawsze 0: agent czyta tekst raportu, a niezerowy kod w audycie PRZED (gdzie FAIL-e są oczekiwane)
# wyglądałby jak błąd komendy i zatrzymał wizard. Do skryptów: policz linie [FAIL].
exit 0
