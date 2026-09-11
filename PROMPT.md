# Zabezpieczenie serwera VPS - instrukcja dla agenta

Ten plik czyta agent (Claude Code) uruchomiony **na komputerze użytkownika** - macOS, Linux albo Windows. Na Windowsie komendy wykonujesz w **Git Bash** (Claude Code używa go automatycznie, gdy jest zainstalowany Git for Windows); `~` to wtedy `C:\Users\<nazwa>`, a `chmod` nic nie robi i nie zgłasza błędu - to w porządku. Jeśli Twoje narzędzie do komend to PowerShell, a nie Bash - zatrzymaj się i poproś użytkownika o instalację Git for Windows (`https://git-scm.com/downloads/win`). Serwer to świeży VPS z **Ubuntu 22.04, 24.04 lub 26.04** (np. Hostinger), na który użytkownik wchodzi jako `root`. Agent nie pracuje na serwerze bezpośrednio - wysyła tam komendy przez `ssh` i sprawdza wynik każdej z nich.

---

## 0. Zasady - czytasz najpierw, obowiązują do końca

1. **Nigdy nie odetnij użytkownika od serwera.** Każda zmiana w SSH (nowy użytkownik, blokada roota, wyłączenie hasła, zapora) ma ten sam rytm: zmiana → test w **nowym** połączeniu → dopiero wtedy następny krok. Bez udanego testu nie idziesz dalej.
2. **`sshd -t` przed każdym restartem SSH.** Konfiguracja z literówką + restart = serwer bez wejścia.
3. **Zapora: najpierw reguła dla SSH, potem włączenie.** Nigdy odwrotnie.
4. **Fail2ban: lista wyjątków z adresem użytkownika zapisana PRZED instalacją pakietu.** Powód w Fazie 5.
5. **Coś się wysypało → STOP.** Pokaż pełny błąd, zapytaj użytkownika. Nie naprawiaj na ślepo, nie powtarzaj komend zmieniających system.
6. **Hasło roota bierzesz tylko raz i tylko wtedy, gdy klucz nie wchodzi** (Faza 1c). Zapis tej rozmowy razem z komendami ląduje na dysku użytkownika, więc hasło, które przez Ciebie przeszło, jest spalone - dlatego w Fazie 8 reset hasła roota w hPanelu jest **obowiązkowy**, nie opcjonalny. Nie pytasz o hasło w Fazie 0 „na zapas".
7. **W każdym `ssh` podajesz `-i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes`, a w testach dodatkowo `-o ControlPath=none`** - żeby test naprawdę otwierał nowe połączenie, a nie wjeżdżał po cichu w już istniejące (gdy użytkownik ma w `~/.ssh/config` współdzielenie połączeń, test „czy nowy użytkownik wchodzi" mógłby zaliczyć się na starej sesji). Po hardeningu serwer daje 3 próby logowania, a SSH bez tych opcji próbuje po kolei **wszystkich** kluczy z agenta - przy kilku kluczach limit wyczerpie się, zanim dojdzie do właściwego, i dostaniesz `Too many authentication failures` mimo poprawnej konfiguracji.
8. **Nie restartujesz serwera** (całej maszyny) bez wyraźnej zgody użytkownika.
9. Placeholdery `IP`, `PORT`, `NOWY_USER`, `ALIAS`, `IP_ADMINA` zawsze zastępujesz **faktycznymi wartościami** - nie zmiennymi shella, nie nawiasami. Dotyczy tylko tych pięciu słów: `$?`, `$SSH_CONNECTION`, `$HOME` i inne zmienne w komendach zostawiasz dokładnie tak, jak są.
10. Każdy blok komend wykonujesz **osobno** i czytasz wynik. Po każdej fazie piszesz użytkownikowi jedno zdanie: co zrobiłeś i co zobaczyłeś.
11. Przy każdym `apt-get` dodajesz `DEBIAN_FRONTEND=noninteractive` i `-o DPkg::Lock::Timeout=600`. Pierwsze chroni przed instalatorem, który zawiesza się na pytaniu, którego w sesji SSH nikt nie zobaczy. Drugie - przed najczęstszym błędem na świeżym VPS-ie: przez pierwsze minuty po starcie system sam robi aktualizacje i trzyma blokadę `dpkg`; bez timeoutu Twoja pierwsza komenda pada na `Could not get lock`.

**Pierwsza wiadomość do użytkownika** (zanim uruchomisz cokolwiek):

> Zanim zaczniemy: otwórz w hPanelu Hostingera zakładkę swojego VPS-a i miej pod ręką przycisk **Web console** (prawy górny róg strony Overview). To awaryjne wejście na serwer, gdyby SSH przestało odpowiadać. Nie musisz go otwierać - wystarczy wiedzieć, gdzie jest.

---

## Faza 0 - zbierz dane

Zapytaj użytkownika (jedno pytanie z listą, nie pięć osobnych):

- **IP serwera** (z hPanelu: VPS → Overview → adres IPv4)
- **Port SSH** - domyślnie `22`
- **Login** - ta instrukcja zakłada `root`. Jeśli użytkownik ma inny login, zatrzymaj się i powiedz mu, że instrukcja jest pisana pod świeży serwer z dostępem roota.
- **Nazwa nowego użytkownika** - małe litery, bez spacji (np. `julia`, `admin`). Jeśli poda wielkie litery, zamień na małe i powiedz o tym.

Hasła **nie pytasz**. Zapamiętaj wartości. Od teraz podstawiasz je we wszystkich komendach.

---

## Faza 1 - klucz SSH (na komputerze użytkownika)

### 1a. Sprawdź, czy klucz jest

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh && ls -la ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub
```

**Jeśli nie ma** - wygeneruj. Bez hasła do klucza (`-N ""`), żeby aplikacje Claude Code, Codex i VS Code łączyły się bez dodatkowego pytania:

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "$(whoami)@$(hostname -s)"
chmod 600 ~/.ssh/id_ed25519
```

### 1b. Sprawdź, czy klucz już wchodzi na serwer

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ControlPath=none -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p PORT root@IP "echo KLUCZ_OK"
```

**Wyszło `KLUCZ_OK`** → klucz działa. Przejdź do Fazy 2.

**Wyszło `REMOTE HOST IDENTIFICATION HAS CHANGED`** → komputer pamięta inny „odcisk" serwera pod tym adresem. Najczęstsza przyczyna: VPS był stawiany od nowa (reinstalacja, nowy serwer po starym IP). **Nie usuwaj wpisu automatycznie** - zapytaj użytkownika: „Czy ten serwer był niedawno tworzony lub reinstalowany pod tym adresem?" Tylko po „tak" usuń stary odcisk i powtórz test; po „nie" STOP - to może być inny serwer albo ktoś po drodze:

```bash
ssh-keygen -R IP; ssh-keygen -R "[IP]:PORT"
```

**Wyszło `Permission denied`** → klucza nie ma na serwerze. Przejdź do 1c.

### 1c. Wgraj klucz na serwer (tylko jeśli 1b nie przeszło)

Zapytaj użytkownika o hasło roota (z hPanelu). Uprzedź jednym zdaniem: „To hasło zostanie w zapisie naszej rozmowy, dlatego na końcu zresetujesz je w hPanelu - przypomnę."

Hasło zapisujesz do tymczasowego pliku, który czyta tylko SSH (`SSH_ASKPASS` to wbudowany mechanizm OpenSSH - działa na macOS, Linuksie i w Git Bash na Windowsie, nic nie instalujesz). Plik kasujesz zaraz po użyciu. Wpisujesz hasło **w linii między `EOF`**, dosłownie, bez cudzysłowów - dzięki temu znaki typu `!`, `$`, `'` niczego nie psują:

```bash
umask 077; cat > ~/.ssh/.askpass.pw <<'EOF'
HASLO_ROOTA
EOF
printf '#!/bin/sh\ncat "$HOME/.ssh/.askpass.pw"\n' > ~/.ssh/.askpass.sh && chmod 700 ~/.ssh/.askpass.sh
```

```bash
SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$HOME/.ssh/.askpass.sh" DISPLAY=:0 ssh-copy-id -i ~/.ssh/id_ed25519.pub -o StrictHostKeyChecking=accept-new -o NumberOfPasswordPrompts=1 -p PORT root@IP; rm -f ~/.ssh/.askpass.pw ~/.ssh/.askpass.sh
```

Oczekiwane: `Number of key(s) added: 1`. `Permission denied` → hasło jest złe; poproś o poprawne (użytkownik może je zresetować w hPanelu: VPS → Overview → **Reset password**) i powtórz oba bloki. Sprawdź, że pliki tymczasowe zniknęły:

```bash
ls ~/.ssh/.askpass.* 2>/dev/null || echo PLIKI_USUNIETE
```

Wróć do testu 1b. Musi wyjść `KLUCZ_OK`. Nie wyszło → STOP, pokaż błąd.

Alternatywa bez hasła (jeśli użytkownik woli): hPanel → VPS → **Settings → SSH keys** → wkleja zawartość `~/.ssh/id_ed25519.pub` (pokaż mu ją przez `cat ~/.ssh/id_ed25519.pub` - to część publiczna, można ją pokazywać), potem test 1b.

---

## Faza 2 - rozpoznanie i aktualizacja systemu

Sprawdź, na czym pracujesz, i zapisz to do podsumowania:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT root@IP ". /etc/os-release && echo \$PRETTY_NAME && systemctl is-enabled ssh.socket 2>/dev/null; true"
```

Oczekiwane: `Ubuntu 22.04...`, `Ubuntu 24.04...` lub `Ubuntu 26.04...`. Inny system → STOP, zapytaj użytkownika.

**Audyt PRZED.** Skrypt z tego repozytorium sprawdza wszystko, co za chwilę ustawisz. Na świeżym serwerze będzie dużo `[FAIL]` - to punkt odniesienia, do którego wrócisz w Fazie 8. Zapisz wynik (skopiuj do swojej odpowiedzi):

```bash
curl -fsSL https://raw.githubusercontent.com/juliajakubowskabiznes/konfiguracja-serwera-vps/main/audit.sh | ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT root@IP "bash -s"
```

Pokaż użytkownikowi listę `[FAIL]` jednym zdaniem: „Na start: X rzeczy do zrobienia."

Świeży obraz z hostingu ma pakiety sprzed tygodni i **pustą listę pakietów** - bez `update` każda instalacja padnie na `Unable to locate package`.

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT root@IP "DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 update -qq && DEBIAN_FRONTEND=noninteractive apt-get -y -qq -o DPkg::Lock::Timeout=600 -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' upgrade"
```

Trwa 2-5 minut (dłużej, jeśli czeka na blokadę). Sprawdź:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT root@IP "apt-get -s upgrade | grep -E '^0 upgraded' > /dev/null && echo AKTUALNY || echo PAKIETY_CZEKAJA; test -f /var/run/reboot-required && echo RESTART_WYMAGANY || echo restart_niepotrzebny"
```

Oczekiwane: `AKTUALNY`. `PAKIETY_CZEKAJA` → powtórz `upgrade` raz; jeśli dalej czekają, pokaż użytkownikowi `apt-get -s upgrade`. Jeśli wyszło `RESTART_WYMAGANY` - **powiedz użytkownikowi, nie restartuj sam**. Restart można zrobić na końcu.

---

## Faza 3 - nowy użytkownik i zamknięcie roota

### 3a. Utwórz użytkownika z sudo bez hasła

Bez hasła do konta (`--disabled-password`), bo logowanie i tak idzie kluczem, a `sudo` dostaje `NOPASSWD` - inaczej każde `sudo` w sesji agenta zawisłoby na pytaniu o hasło, którego konto nie ma.

Najpierw upewnij się, że klucz roota istnieje (to on zostanie skopiowany nowemu użytkownikowi):

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT root@IP "test -s /root/.ssh/authorized_keys && echo KLUCZ_JEST || echo BRAK_KLUCZA"
```

`BRAK_KLUCZA` → wróć do Fazy 1c. `KLUCZ_JEST` → dalej:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT root@IP "adduser --disabled-password --gecos '' NOWY_USER && usermod -aG sudo NOWY_USER"
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT root@IP "mkdir -p /home/NOWY_USER/.ssh && cp /root/.ssh/authorized_keys /home/NOWY_USER/.ssh/authorized_keys && chown -R NOWY_USER:NOWY_USER /home/NOWY_USER/.ssh && chmod 700 /home/NOWY_USER/.ssh && chmod 600 /home/NOWY_USER/.ssh/authorized_keys"
```

Plik `sudoers` najpierw walidujesz w `/tmp`, dopiero potem wgrywasz - błąd składni w `/etc/sudoers.d/` wyłącza `sudo` dla wszystkich:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT root@IP "printf 'NOWY_USER ALL=(ALL) NOPASSWD:ALL\n' > /tmp/sudoers.tmp && visudo -cf /tmp/sudoers.tmp && install -m 0440 -o root -g root /tmp/sudoers.tmp /etc/sudoers.d/NOWY_USER && rm -f /tmp/sudoers.tmp && echo SUDOERS_OK"
```

Oczekiwane: `parsed OK` i `SUDOERS_OK`.

### 3b. 🔴 TEST - nowy użytkownik wchodzi i ma sudo

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ControlPath=none -p PORT NOWY_USER@IP "whoami && sudo -n whoami"
```

Oczekiwane dwie linijki: `NOWY_USER` i `root`. **Jeśli nie - STOP.** Nie ruszaj konfiguracji SSH, dopóki to nie działa. Root wciąż wchodzi, nic nie jest zepsute.

### 3c. Zablokuj roota i logowanie hasłem

Ubuntu wczytuje pliki z `/etc/ssh/sshd_config.d/` **na początku** głównej konfiguracji, a w sshd **wygrywa pierwsze wystąpienie** ustawienia. Plik `00-` jest alfabetycznie pierwszy, więc bije zarówno `50-cloud-init.conf`, jak i `sshd_config`. Dlatego nic nie edytujesz `sed`-em - dopisujesz jeden plik. Wyjątek od tej reguły to bloki `Match` w innych plikach (na świeżym Ubuntu ich nie ma) - dlatego niżej **nie ufasz plikom, tylko `sshd -T`**, które pokazuje, co sshd faktycznie zastosuje.

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "sudo tee /etc/ssh/sshd_config.d/00-hardening.conf > /dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF"
```

Sprawdź składnię i to, co sshd **faktycznie** zastosuje:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "sudo sshd -t && sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|maxauthtries)'"
```

`sshd -t` ma nie wypisać nic. `sshd -T` ma pokazać: `permitrootlogin no`, `passwordauthentication no`, `kbdinteractiveauthentication no`, `maxauthtries 3`. **Cokolwiek innego → STOP, nie restartuj.**

Samo `-T` pokazuje konfigurację ogólną. Bloki `Match` (dla konkretnego użytkownika lub adresu) uwzględnia dopiero `-T -C` z parametrami połączenia - sprawdź więc to samo dla nowego użytkownika **i** dla roota, z adresu, z którego się łączysz:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "A=\$(echo \$SSH_CONNECTION | awk '{print \$1}'); for U in NOWY_USER root; do echo \"== \$U z \$A:\"; sudo sshd -T -C user=\$U,host=IP,addr=\$A | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|maxauthtries) '; done"
```

Oba bloki mają pokazać te same cztery wartości co wyżej. Różnica między nimi albo między nimi a `-T` = jakiś plik ma blok `Match`, który nadpisuje hardening → STOP, pokaż użytkownikowi `grep -rn '^Match' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/`.

Restart usługi (istniejące sesje nie padają; na 24.04 SSH jest uruchamiany przez socket, ale restart `ssh.service` przeładowuje konfigurację):

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "sudo systemctl restart ssh"
```

### 3d. 🔴 TEST - po restarcie

Nowy użytkownik nadal wchodzi:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ControlPath=none -p PORT NOWY_USER@IP "echo NADAL_OK"
```

Root już nie (to jest dobra wiadomość):

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ControlPath=none -o ConnectTimeout=10 -p PORT root@IP "echo ROOT_WSZEDL" ; echo "kod wyjscia: $?"
```

Oczekiwane: `Permission denied` i kod wyjścia `255`. Gdyby wypisało `ROOT_WSZEDL` - konfiguracja nie zadziałała, wróć do 3c.

Hasło też już nie działa - ta komenda wymusza próbę logowania hasłem (pomija klucz) dla nowego użytkownika:

```bash
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no -o BatchMode=yes -o ControlPath=none -o ConnectTimeout=10 -p PORT NOWY_USER@IP "echo HASLO_DZIALA" ; echo "kod wyjscia: $?"
```

Oczekiwane: `Permission denied (publickey)` - serwer nie proponuje już hasła w ogóle. `HASLO_DZIALA` albo pytanie o hasło → wróć do 3c.

**Od tego momentu wszystkie komendy wykonujesz jako `NOWY_USER` z `sudo`.**

> Ta próba logowania rootem zostawia w logu jeden nieudany wpis. To ważne dla Fazy 5.

---

## Faza 4 - zapora (UFW)

Domyślnie: nic nie wchodzi, wszystko może wychodzić. Wyjątki: SSH, HTTP (80), HTTPS (443).

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o DPkg::Lock::Timeout=600 ufw"
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "sudo ufw default deny incoming && sudo ufw default allow outgoing && sudo ufw allow PORT/tcp && sudo ufw allow 80/tcp && sudo ufw allow 443/tcp"
```

**Zanim włączysz** - sprawdź, że port SSH jest na liście:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "sudo ufw show added"
```

Widzisz `ufw allow PORT/tcp`? Dopiero teraz:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "sudo ufw --force enable && sudo ufw status verbose"
```

🔴 TEST:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ControlPath=none -p PORT NOWY_USER@IP "echo ZAPORA_OK"
```

---

## Faza 5 - fail2ban

**Dlaczego lista wyjątków idzie przed instalacją.** Pakiet `fail2ban` uruchamia ochronę SSH **już w trakcie** `apt-get install`, z domyślnymi ustawieniami. Przy starcie przelicza nieudane logowania z ostatnich minut - a w Fazie 3d celowo zrobiłeś jedno (test roota). Jeśli użytkownik testował coś jeszcze ręcznie, wpisów jest więcej. Bez wyjątku dla jego adresu fail2ban potrafi go **zbanować zaraz po starcie**, zanim zdążysz cokolwiek poprawić. Objaw: `Connection refused` natychmiast, nie timeout.

### 5a. Ustal adres użytkownika

Adres, z którego przychodzi bieżące połączenie SSH:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "echo \$SSH_CONNECTION | awk '{print \$1}'"
```

Pokaż go użytkownikowi i zapytaj, czy to jego adres (np. „Twój adres to `IP_ADMINA` - zgadza się?"). Jeśli używa VPN, adres może się zmieniać - powiedz mu, że wpis wtedy z czasem przestanie chronić (ale nie zaszkodzi).

### 5b. Konfiguracja PRZED instalacją

`backend = systemd` jest konieczny: od Ubuntu 24.04 nie ma pliku `/var/log/auth.log`, fail2ban musi czytać dziennik systemowy. Bez tego usługa nie wystartuje. `journalmatch` wskazuje, których wpisów dziennika szukać - na Ubuntu usługa nazywa się `ssh.service` (nie `sshd.service`), a od OpenSSH 9.8 (Ubuntu 26.04) proces połączenia nazywa się `sshd-session`; `+` znaczy „lub", więc wpis obejmuje wszystkie warianty.

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "sudo mkdir -p /etc/fail2ban && sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 IP_ADMINA
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = PORT
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session
EOF"
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "grep -E '^ignoreip' /etc/fail2ban/jail.local"
```

Ma wypisać linijkę z **faktycznym** adresem użytkownika. Jeśli widzisz literalne `IP_ADMINA` - placeholder nie został podstawiony, popraw zanim pójdziesz dalej.

### 5c. Instalacja i start

Najpierw moduł systemd, potem fail2ban - w jednej komendzie apt nie gwarantuje kolejności, a fail2ban bez modułu pada przy pierwszym starcie:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o DPkg::Lock::Timeout=600 python3-systemd"
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o DPkg::Lock::Timeout=600 fail2ban"
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "sudo systemctl enable fail2ban; sudo systemctl restart fail2ban; sudo systemctl is-active fail2ban && sudo fail2ban-client status && sudo fail2ban-client status sshd"
```

Oczekiwane: `active`, `Jail list: sshd`, `Currently banned: 0`, pusta `Banned IP list`. Jeśli w `Banned IP list` jest adres użytkownika - odbanuj natychmiast, póki masz sesję:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "sudo fail2ban-client set sshd unbanip IP_ADMINA"
```

---

## Faza 6 - automatyczne aktualizacje bezpieczeństwa

System sam instaluje łatki bezpieczeństwa (tylko je, nie nowe wersje programów). **Bez automatycznego restartu** - na serwerze będą pracować agenty i kontenery, restart w nocy zerwałby im robotę. Gdy jądro będzie wymagać restartu, użytkownik zrobi to sam, kiedy mu pasuje.

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o DPkg::Lock::Timeout=600 unattended-upgrades"
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<'EOF'
APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Unattended-Upgrade \"1\";
APT::Periodic::AutocleanInterval \"7\";
EOF"
```

Aktualizacje napędzają dwa **timery** systemd - to je sprawdzasz, nie samą usługę:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p PORT NOWY_USER@IP "systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer && systemctl list-timers 'apt-daily*' --no-pager && sudo unattended-upgrade --dry-run -v 2>&1 | tail -5"
```

Oczekiwane: dwa razy `enabled`, oba timery na liście z datą następnego uruchomienia, a dry-run kończy się bez błędu (może napisać, że nie ma nic do zainstalowania - to w porządku).

---

## Faza 7 - skrót do logowania (na komputerze użytkownika)

Zapytaj użytkownika, jak ma się nazywać skrót (np. `vps`, `hermes`, `serwer`). To słowo zastąpi całą komendę `ssh -p PORT NOWY_USER@IP` - w terminalu, w VS Code, w aplikacji Claude Code i w Codex.

W `~/.ssh/config` **wygrywa pierwsze wystąpienie** ustawienia, dlatego blok wstawiasz na **początek** pliku - gdyby użytkownik miał niżej ogólny blok `Host *` z innym kluczem lub użytkownikiem, wpis dopisany na końcu by z nim przegrał.

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/config && chmod 600 ~/.ssh/config
grep -nE "^\s*Host\s+(ALIAS|\*)\s*$" ~/.ssh/config; true
```

**Jeśli wypisało `Host ALIAS`** - pokaż użytkownikowi obecny blok i zapytaj, czy podmienić. Nie dubluj. **Jeśli wypisało `Host *`** - powiedz użytkownikowi, że taki blok istnieje i że nowy wpis idzie przed nim. **Jeśli nic nie wypisało** - dopisz na początek:

```bash
printf 'Host ALIAS\n  HostName IP\n  User NOWY_USER\n  Port PORT\n  IdentityFile ~/.ssh/id_ed25519\n  IdentitiesOnly yes\n  AddKeysToAgent yes\n\n' | cat - ~/.ssh/config > ~/.ssh/config.new && mv ~/.ssh/config.new ~/.ssh/config && chmod 600 ~/.ssh/config
```

🔴 TEST - tym razem **bez** `-i` i `-p`, bo właśnie to sprawdzasz:

```bash
ssh -o BatchMode=yes -o ControlPath=none ALIAS "echo SKROT_OK"
```

---

## Faza 8 - podsumowanie

Pokaż użytkownikowi tabelę:

| Co | Stan |
|---|---|
| System | Ubuntu X, zaktualizowany, restart wymagany: tak/nie |
| Klucz SSH | `~/.ssh/id_ed25519` (nowy / istniejący) |
| Użytkownik | `NOWY_USER` z sudo, root zablokowany przez SSH |
| Logowanie hasłem | wyłączone |
| Zapora | aktywna: PORT, 80, 443 |
| Fail2ban | aktywny, wyjątek dla `IP_ADMINA` |
| Auto-aktualizacje | włączone, bez auto-restartu |
| Skrót | `ssh ALIAS` |

Plus wszystko, co odbiegło od planu: pominięte kroki, powtórzone komendy, niezgodne wyniki.

Potem **końcowy test - robisz go Ty**, nie użytkownik. Trzy sprawdzenia, każde osobno, wyniki wklejasz użytkownikowi dosłownie:

```bash
ssh -o BatchMode=yes -o ControlPath=none ALIAS "echo SKROT_DZIALA && whoami && sudo -n whoami"
```
Oczekiwane: `SKROT_DZIALA`, `NOWY_USER`, `root`.

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ControlPath=none -o ConnectTimeout=10 -p PORT root@IP "echo ROOT_WSZEDL" ; echo "kod wyjscia: $?"
```
Oczekiwane: `Permission denied`, kod `255`. `ROOT_WSZEDL` = błąd, wróć do 3c.

```bash
ssh -o BatchMode=yes -o ControlPath=none ALIAS "sudo ufw status | head -1 && sudo systemctl is-active fail2ban && sudo sshd -T | grep -E '^(passwordauthentication|permitrootlogin) '"
```
Oczekiwane: `Status: active`, `active`, `passwordauthentication no`, `permitrootlogin no`.

**Audyt PO** - ten sam skrypt, co w Fazie 2, tym razem przez skrót i z `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/juliajakubowskabiznes/konfiguracja-serwera-vps/main/audit.sh | ssh -o BatchMode=yes -o ControlPath=none ALIAS "sudo bash -s"
```

Pokaż użytkownikowi zestawienie: każda pozycja, która w Fazie 2 była `[FAIL]`, a teraz jest `[PASS]`. Oczekiwane: `FAIL: 0`.

Wszystko zgodne → napisz użytkownikowi wprost: **„Serwer jest zabezpieczony. Zapasowe okno możesz zamknąć."** Cokolwiek się nie zgadza → STOP, pokaż co i wróć do właściwej fazy.

Na koniec dwie rzeczy, których nie możesz zrobić za użytkownika - poproś go o nie:

1. **Reset hasła roota w hPanelu** (VPS → Overview → **Reset password**). Jeśli w Fazie 1c hasło przeszło przez Ciebie - to jest **obowiązkowe**, nie „warto": hasło leży w zapisie tej rozmowy, a w Web console nadal działa. Poproś o potwierdzenie „zresetowane", zanim zakończysz.
2. Jeśli w Fazie 2 system prosił o restart: zapytaj o zgodę i wykonaj `ssh ALIAS "sudo reboot"`; po minucie sprawdź `ssh -o BatchMode=yes -o ControlPath=none ALIAS "echo PO_RESTARCIE_OK"`.
