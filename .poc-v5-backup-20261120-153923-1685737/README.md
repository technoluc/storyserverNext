# Nextory → Audiobookshelf | V5 dynamische catalogus

V5 breidt de op iPhone bevestigde **werkende V4** uit met **live Nextory-zoeken**, **19 Nederlandse categorieën**, een automatische **'Nieuw ontdekt'**-bibliotheek en een duurzame metadata-index. Er is **geen `add-book.sh` meer nodig**. De volledige HLS-afspeelroute voor de bestaande twee boeken blijft onveranderd.

**Belangrijk verschil:** 'doorzoek en blader door het beschikbare aanbod' betekent niet dat er een complete offline kopie van de Nextory-catalogus is. Nextory biedt geen door ons geverifieerde officiële volledige export. De server vraagt zoekresultaten en categoriepagina's **op aanvraag** op; de metadata-index groeit automatisch en periodiek. We kunnen daarom niet claimen dat ieder van de miljoenen titels ooit in de index terechtkomt.

## Wat kan de iPhone nu doen?

- **Zoeken in de oorspronkelijke Audiobookshelf-app**: de app roept `GET /api/libraries/{id}/search?q=...` aan. V5 zoekt live bij Nextory via het onofficiële discovery-endpoint `GET /discovery/v1/search/products/books`, met `format=audiobook`. Nieuwe resultaten worden direct beschikbaar als virtuele items, ook als ze nog nooit eerder zijn toegevoegd.
- **Bladeren via bibliotheekkeuze**: naast **Nextory - Alle ontdekte boeken** en **Nextory - Nieuw ontdekt** verschijnen **19 genre-bibliotheken** uit de Nederlandse Nextory-catalogus (zoals Misdaad, Fantasy, Kinderboeken). Selecteer een categorie in de normale bibliotheekwisselaar. De eerste pagina en volgende pagina's worden op aanvraag uit de Nextory-webcatalogus gelezen, door Nextory-productmetadata geverifieerd en alleen voor HLS-luisterboeken geïndexeerd.
- **Nieuwe boeken ontdekken**: een aparte, automatisch herhaalde scan van de publieke Nextory-start-, luisterboek- en categoriepagina's is standaard elke **zes uur** ingeschakeld. De inhoud van **Nieuw ontdekt** volgt die pagina's. Dit betekent *nieuw door onze server ontdekt*, niet noodzakelijk *op die dag gepubliceerd*. Er is geen handmatige toevoeging of containerherstart nodig.
- **Echte metadata**: titel, auteurs, voorlezers, beschrijving, uitgever, cover-URL, taal, eventuele serie/ISBN/publicatiedatum. Ontbrekende broninformatie wordt niet verzonnen.
- **Echte audio**: pas wanneer een gebruiker een titel opent of afspeelt, vraagt de server het complete Nextory-HLS-pakket en berekent de trackindeling. Geen voorafgaand audiobestand of boekdownload. Doorlopende tracks, pauzeren, spoelen en luisterpositie uit v4 blijven bewaard.

## Installatie: upgrade van de bestaande, werkende V4

Download de ZIP op de **zelfde Docker-host** als de huidige POC en plaats hem als `/tmp/nextory-abs-virtual-poc-v5.zip`.

Ga met de terminal naar de **huidige V4-projectmap** met `.env`, `docker-compose.yml`, `book-ids.txt` en `app/main.py` en voer uit:

```sh
ZIP=/tmp/nextory-abs-virtual-poc-v5.zip
clear
unzip -tq "$ZIP" || exit 1
unzip -p "$ZIP" nextory-abs-virtual-poc-v5/upgrade.sh | sh -s -- "$ZIP"
```

De upgrade:
1. maakt een backup `.poc-v4-backup-.../` met de eerdere v4-code;
2. **behoudt je bestaande** `.env`, `NEXTORY_CONFIG_SOURCE` en `book-ids.txt` (dus ook beide bestaande boeken en Nextory-login);
3. **laat** de bestaande `docker-compose.yml`, Dockerfile en de named volume `nextory-progress` **ongewijzigd**; de nieuwe metadata-index staat in hetzelfde persistente volume onder `/state/catalog.sqlite3` en bevat geen audio, sleutels of tokens;
4. herbouwt en **hermaakt uitsluitend `nextory-abs-poc`** via `docker compose up -d --build --force-recreate nextory-abs-poc`, dus niet de echte Audiobookshelf of de andere `audiobook-dl-web` node;
5. voert de V4-playback-regressietest (`smoke.sh`) en de aparte live zoektest (`catalog-smoke.sh`) uit.

De v4-playbacktest vraagt alleen de oorspronkelijke HLS-playlists en covers van jouw al werkende boeken op en geen audiobestanden. De catalogus-smoke vraagt alleen metadata op. Valt de onofficiële Nextory-zoek-API of openbare website uit, dan kan afspelen van eerder werkende boeken blijven werken, terwijl de nieuwe bladerfunctie (deels) onbeschikbaar is.

**Let op:** de online werking van de Nextory-zoekservice en het website-categorieformaat kan uitsluitend op jouw Docker-host met netwerk en werkende account worden bevestigd; in de ontwikkelomgeving zijn deze externe bronnen niet bereikbaar. Alle offline tests simuleren hun responses; ze zijn geen bewijs van een werkende productiecatalogus.

## Na de upgrade: zonder handmatige toevoeging

1. Open de **zelfde** Audiobookshelf-server op je iPhone. Zo nodig sluit de app volledig af, open opnieuw of wissel van bibliotheek om de nieuwe bibliotheeklijst te vernieuwen.
2. Selecteer **Nextory - Nieuw ontdekt** om de automatisch gevonden boeken te zien. De eerste scan kan nog bezig zijn.
3. Selecteer **Nextory - Misdaad** of een andere Nextory-bibliotheek om door genrepagina's te bladeren.
4. Gebruik het gewone **Zoeken** van de Audiobookshelf-app. Zoek bijvoorbeeld op een boek of auteur die **niet** in je huidige twee boeken voorkomt. Open een resultaat en probeer Stream. Je hoeft hiervoor geen `add-book.sh` uit te voeren.
5. Je bestaande **Hier gebeurt nooit iets** (7207495) en **De heks** (7257862) blijven in **Alle ontdekte boeken** afspeelbaar met dezelfde item-ID's en opgeslagen luisterpositie.

De bestaande V4-bestandslijst is nog aanwezig voor achterwaartse compatibiliteit, maar nieuwe titels hoeven er niet in. Het legacy `add-book.sh` zit nog in het project maar is **geen onderdeel van de nieuwe workflow**.

## Diagnostiek zonder secrets

```sh
clear
sh smoke.sh
sh catalog-smoke.sh
```

Voor de actuele catalogusstatus (aantal geïndexeerde boeken, recente scans, eventuele fout) zie je ook `GET /api/poc/discovery-status` met de Audiobookshelf Bearer-token. Plaats deze token nooit in chat of logs. Een aparte `POST /api/poc/discovery-refresh` bestaat voor diagnose, maar handmatig verversen is **niet nodig** voor normale bediening.

De index bewaart geen credentials en geen audiobestanden. `config/audiobook-dl.toml` blijft in de bestaande alleen-lezen bind mount, niet in het ZIP-archief. De benodigde opslag is metadata en luisterpositie; een omvangrijke lokale catalogus zal wel database-opslag vergen, maar geen audio-opslag.

## Rollback naar de werkende V4

De upgrade toont iets als `BACKUP=.poc-v4-backup-20261120-XXXXXX-12345`. Voer in de POC-map uit:

```sh
sh rollback.sh '.poc-v4-backup-YYYYMMDD-HHMMSS-PID'
```

Deze opdracht herstelt uitsluitend de projectcode en herbouwt de POC-container; de bestaande `.env`, Nextory-credentials, `book-ids.txt`, de Docker-state-volume en luisterposities blijven behouden. De V5 metadata-index blijft ongebruikt in de volume liggen en kan later opnieuw worden benut.

## Reikwijdte en aandachtspunten

- **Compleet bladeren**: Nextory toont mogelijk tienduizenden boeken per genre en heeft een eigen paginering. V5 ondersteunt vooruitbladeren en nieuwe zoekresultaten, maar garandeert geen uitputtende ingest van álle wereldwijd beschikbare boeken. De bronwebpagina kan veranderen, een CAPTCHA of blokkade tonen, waardoor (vooral) categorieën niet werken. Deze route is een onofficiële testintegratie.
- **Synchronisatie**: de app ververst haar eigen bibliotheekinformatie niet per se direct. V5 vereist geen herstart; soms moet je in de app naar de bibliotheek teruggaan of wisselen.
- **Nieuwe titels**: de standaardscancyclus is zes uur (`CATALOG_REFRESH_SECONDS=21600`). Dat is geen real-time push-notificatie en controleert geen compleet Nextory-releasearchief.
- **Toegangsrechten**: de onofficiële Nextory-API's en de gebruiksvoorwaarden bepalen of externe integratie is toegestaan. Alleen titels met een geverifieerde HLS-boekvariant worden getoond. Er is geen DRM-omzeiling, segmentopslag of volledige boekdownload.
- **Beveiliging**: deze proefserver blijft binnen een vertrouwd netwerk. HLS-sessie-URLs functioneren als tijdelijke toegangscapabilities. Publiceer poort 13378 niet ongecontroleerd op het internet.
- **Serverresourcegebruik**: metadata wordt begrensd opgehaald, pagina voor pagina. De POC heeft geen professioneel catalogus-backend met echte push-updates, geavanceerde meergebruikersrechten of schaalbare caching.

## Implementatie en tests

De nieuwe code bestaat uit `app/discovery.py` (SQLite-index / genre-index / website-crawler), `app/nextory.py` (authentieke metadata-only product- en zoekrequests) en wijzigingen in `app/main.py` (normale Audiobookshelf-API-bibliotheken, live zoeken, paginate, automatische verversing). De originele V4-HLS-proxy `app/hls_proxy.py` en de voortgangsopslag `app/progress.py` zijn behouden.

Bij het bouwen zijn **29 offline Python-tests** voor het bestaande protocol en de ontdekking geslaagd, met gesimuleerde Nextory-API- en webresponses. Er is geen beschermde audio, testaudio of verzonnen cover mee verpakt. De live Nextory-validatie en iPhone-acceptatietest moeten op jouw bestaande server plaatsvinden.
