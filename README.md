# Halo

Halo maakt van je repositories draaiende omgevingen (_spaces_): de apps in containers, de databases ernaast, elke app op een eigen adres. Op je eigen computer of op een server voor je team.

Hier staan de downloads van Halo v2. Alle releases zijn voorlopig **testversies** (pre-releases).

## Installeren

Op Linux (x64), als gewone gebruiker met `sudo`:

```sh
curl -fsSL https://raw.githubusercontent.com/fromorbit/halo-releases/main/install.sh | sh
```

Dat is alles. De installer:

1. haalt de nieuwste versie op en controleert het archief tegen `SHA256SUMS`;
2. zet `halo` in `~/.local/bin` en de web-UI in `~/.local/share/halo`;
3. kiest de modus `local`: alleen deze computer, zonder accounts;
4. zet een container-engine (Podman), de basisimages (Node 20 en 22) en een systemd-dienst klaar. Wat root nodig heeft, noemt hij eerst: `sudo` vraagt één keer je wachtwoord en je zegt één keer ja;
5. wacht tot Halo antwoordt en zegt waar je hem opent:

```
Halo is running (this computer only).
Open Halo:        http://127.0.0.1:7788
First workspace:  halo repo scan <folder with your app>
```

Staat `~/.local/bin` nog niet in je `PATH`, dan zegt de installer hoe je dat regelt.

**Liever eerst lezen wat je draait?**

```sh
curl -fsSLO https://raw.githubusercontent.com/fromorbit/halo-releases/main/install.sh
less install.sh
sh install.sh
```

**Wat je nodig hebt**

- Linux x64 met systemd. Als root weigert de installer: draai hem als je gewone gebruiker (of geef `--allow-root` als je het echt zo wilt).
- `curl`, `tar`, `gzip` en `sha256sum`.
- Een engine hoeft er nog niet te zijn. Is Podman er, dan gebruikt de installer Podman; anders een Docker die al draait; anders installeert hij Podman.

Zonder terminal (in een script) vraagt de installer niets. Dan installeert hij alleen het programma, tenzij je `--yes`, `--mode` of `--with-engine` meegeeft. Ontbreekt er iets, dan stopt hij meteen met de regel die het oplost.

`sh install.sh --help` toont alle opties, zoals `--engine podman|docker`, `--images all` (ook PHP, groot), `--no-service` en `--prefix <map>`.

## Een server voor je team

Op de server, in een ssh-sessie met terminal (of `ssh -t server '…'`, zodat `sudo` en het wachtwoord gevraagd kunnen worden):

```sh
curl -fsSL https://raw.githubusercontent.com/fromorbit/halo-releases/main/install.sh | sh -s -- --mode server --host <domein> --owner <naam>
```

- `--host` is het basisdomein voor de adressen van de spaces, en verplicht. Geen eigen domein? Gebruik je IP met streepjes plus `.sslip.io`, bijvoorbeeld `--host 192-168-1-50.sslip.io`.
- `--owner` maakt het eerste account, de eigenaar. Het wachtwoord (minstens 10 tekens) vraagt de installer op de terminal.
- Aan het eind staat het adres: `http://<domein>:7788` (in de desktop-app: **Host toevoegen** met dat adres). De spaces staan op `http://<space>.<domein>:7790`: zet poort 7788 en 7790 open.
- Met TLS achter Caddy geef je `--public-url https://<domein>` in plaats van `--host`. Halo luistert dan alleen op de server zelf, de installer maakt de Caddy-configuratie (`~/.halo/caddy/Caddyfile`) en alleen poort 80 en 443 hoeven open. Zonder TLS gaan wachtwoorden onversleuteld over het netwerk.

Zonder vragen, bijvoorbeeld vanuit een script (`sudo` moet dan zonder wachtwoord werken):

```sh
curl -fsSL https://raw.githubusercontent.com/fromorbit/halo-releases/main/install.sh \
  | HALO_OWNER_PASSWORD="$(cat ~/.halo-owner)" sh -s -- --mode server --host <domein> --owner <naam> --yes
```

## Kanalen

Welke versie je krijgt, staat in [`kanalen.json`](kanalen.json).

| Kanaal               | Wat je krijgt                   |
| -------------------- | ------------------------------- |
| `stable` (standaard) | de nieuwste stabiele versie     |
| `beta`               | de nieuwste van stabiel en test |

**Nu** is er nog geen stabiele versie. Zonder `--channel` installeert de installer daarom de nieuwste testversie, zegt dat erbij en volgt daarna `beta`. Met `--channel stable` stopt hij, tot de eerste stabiele versie er is. Kies zelf met bijvoorbeeld `| sh -s -- --channel beta`; Halo onthoudt het kanaal voor `halo update`.

## Desktop-app en Windows

Alle bestanden staan op de [releasepagina](https://github.com/fromorbit/halo-releases/releases); de bovenste release is de nieuwste.

| Je hebt                          | Download                                           | Eerste keer                                                                                                                   |
| -------------------------------- | -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Windows 10 of 11                 | `Halo-Setup-<versie>.exe`                          | Dubbelklikken; de app zet WSL, Podman en Halo zelf klaar. SmartScreen: "Meer informatie", dan "Toch uitvoeren"                 |
| Linux met een bureaublad         | `Halo-<versie>.AppImage` of `Halo-<versie>.deb`    | AppImage: `chmod +x`; Ubuntu 24.04: `sudo apt install libfuse2t64`. Het .deb: `sudo apt install ./Halo-<versie>.deb`          |
| Een Linux-server                 | `install.sh`                                       | Zie [Een server voor je team](#een-server-voor-je-team)                                                                       |
| Windows, alleen de opdrachtregel | `halo-cli-<versie>-windows-x64.zip` (of de `.exe`) | Geen installer: dubbelklikken opent geen app. Voor PowerShell en scripts                                                      |
| Mac                              | nog geen bestand                                   | Draai Halo op een Linux-server en open het adres in je browser                                                                |

Verder in elke release: `halo-<versie>-linux-x64.tar.gz` (het programma voor Linux en WSL; de installer en de app gebruiken het), `SHA256SUMS`, `RELEASE-NOTES.md` (wat er nieuw is) en `latest.yml` / `latest-linux.yml` (de updatelijsten van de app; zelf niet nodig).

## Downloads controleren

Zet de bestanden en `SHA256SUMS` in één map en draai daar:

```sh
sha256sum -c --ignore-missing SHA256SUMS
```

Elk bestand moet `OK` geven. Voor het Linux-archief doet de installer dit zelf. `SHA256SUMS` komt van dezelfde plek als de bestanden: het vangt een beschadigde download, maar bewijst niet dat een bestand echt is. De bestanden zijn nog niet ondertekend.

## Bijwerken en verwijderen

```sh
halo update
```

`halo update` volgt het kanaal dat je bij de installatie kreeg. De installer opnieuw draaien kan ook: een bestaande installatie houdt haar modus.

Verwijderen:

```sh
halo uninstall           # vraagt eerst; je gegevens in ~/.halo blijven staan
halo uninstall --purge   # haalt ook ~/.halo weg
```

Of met de installer, die het programma, de web-UI en de systemd-dienst weghaalt (een systeemdienst met `sudo`) en `~/.halo` laat staan:

```sh
curl -fsSL https://raw.githubusercontent.com/fromorbit/halo-releases/main/install.sh | sh -s -- --uninstall
```

---

Alle releases zijn voorlopig testversies: ze kunnen nog veranderen en zijn niet ondertekend. Wat er per versie nieuw is en wat nog niet bewezen is, staat in `RELEASE-NOTES.md` bij elke release.
