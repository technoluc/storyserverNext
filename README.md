# storyserverNext

Een Nextory-server die je als aparte server kunt toevoegen in AudioBooth of Audiobookshelf.

## Starten

1. Kopieer [`.env.example`](.env.example) naar `.env` in deze map.
2. Vul `NEXTORY_USERNAME` en `NEXTORY_PASSWORD` in. Kies voor `TEST_PASSWORD` een apart wachtwoord van minstens 12 tekens voor je lokale server.
3. Start de server:

   ```sh
   docker compose up -d
   ```

   Docker Compose bouwt de image bij de eerste start. Je hebt geen installatiescripts, apart TOML-bestand of bestaande audiobook-dl-installatie nodig.

4. Voeg in AudioBooth of Audiobookshelf `http://<ip-van-je-dockerhost>:13378` toe. Log in als `test` met je `TEST_PASSWORD`.

De voorbeeldconfiguratie maakt de server bereikbaar op je lokale netwerk. Gebruik `BIND_IP=127.0.0.1` voor toegang vanaf alleen de Docker-host. Bewaar `.env` lokaal en stuur dat bestand niet mee.

Met `docker compose ps` zie je of de server gezond is. Met `docker compose logs --tail=100 nextory-abs-poc` lees je de recente meldingen. Doe na wijzigingen aan de broncode `docker compose up -d --build`.

## Catalogus

De bestaande SQLite-catalogus blijft behouden en wordt gebruikt voor snel bladeren en als fallback. Zoeken gebruikt standaard de live Nextory-webdiscovery, zonder accounttokens. Nieuwe zoekresultaten worden opgeslagen. Boekdetails behouden hun bestaande, begrensde prewarming (uitsluitend bij een uitgebreid detailverzoek, nooit tijdens een catalogusscan). Prewarming bereidt de stream voor en kan dus wel accountauthenticatie vereisen.

| Optie in .env | Standaard | Betekenis |
|---|---|---|
| `CATALOG_AUTOSYNC` | `0` | Automatische catalogusopbouw voorlopig uit; opt-in na verificatie van de openbare metadata-API. |
| `CATALOG_LIVE_SEARCH` | `1` | Live openbaar zoeken met lokale fallback. |
| `NEXTORY_DETAIL_PREWARM` | `1` | Bestaande prewarming bij uitgebreid boekdetail. |

Covers gebruiken opgeslagen openbare URLs, zonder reader-authenticatie. Productpreviews en zoeken gebruiken een afzonderlijke openbare HTTP-sessie. Bij 401, 403 of 429 op een openbare discovery-route wacht die route minstens een uur; er is geen automatische terugval naar een accountlogin. De openbare zoekroute was al aanwezig in de vorige implementatie; anonieme productpreviews moeten nog live worden geverifieerd.

Een nieuwe installatie met lege catalogus kan titels via live zoeken toevoegen. De optionele handmatige recente-refresh (`POST /api/poc/discovery-refresh`) en de optionele catalogussynchronisatie gebruiken openbare metadata. De scan pauzeert categorieën bij herhaalde bronpagina's, drie pagina's zonder groei of maximaal 100 bronpagina's. Bij fouten wacht een categorie minstens een uur; niet-geschikte previews worden zeven dagen onthouden. Pauzeredenen staan in `/api/poc/catalog-status`. De grenzen zijn conservatief en geen bewijs dat de catalogus compleet is.

De backend logt niet meer iedere twintig minuten opnieuw in. Bij HTTP 401, 403 of 429 vanuit een geauthenticeerde route wordt verdere accounttoegang in het proces geblokkeerd, zonder automatisch opnieuw inloggen. Controleer het account voordat je de server opnieuw start. De eerste login bij prewarming of afspelen kan nog altijd een andere gebruiker verdringen als het abonnement geen gelijktijdig gebruik toestaat.

Offline regressietests: `python -m unittest discover -s tests -p test_session_safety.py`.

## Afspelen in AudioBooth

AudioBooth krijgt standaard een virtuele M4B voor ieder boek. De server maakt de audio op aanvraag met één FFmpeg-worker en deelt maximaal 16 MiB aan audiocache tussen alle sessies, met maximaal 8 MiB per sessie. Bij ruimtegebrek verdwijnen de minst recent gebruikte audioblokken uit de cache. Een nog geldige sessie kan ze opnieuw genereren. Als een boek niet als M4B kan worden voorbereid, gebruikt de server de bestaande HLS-route. Andere clients blijven HLS gebruiken.

Heb je eerder `NEXTORY_TEST_VIRTUAL_M4B_BOOK` in je `.env` gezet, verwijder dan die regel of zet de waarde op `all` om alle boeken te gebruiken.

Op de bibliotheekpagina toont **Verder luisteren** boeken met opgeslagen, onafgeronde voortgang. **Recent getest** toont boeken waarvoor de server een afspeelsessie heeft aangemaakt, ook als die poging verderop vastliep. De recentste 2.000 sessies blijven in het Docker-volume staan, inclusief titel, tijd en afspeelformaat. Een afspeelsessie geeft aan dat Play is geprobeerd. Luistertijd en positie in de geschiedenis komen uit de voortgang die de speler doorgeeft.

## Bestaande installatie bijwerken

Voeg de twee Nextory-variabelen toe aan je bestaande `.env` en behoud je huidige serverwachtwoord. Als `TEST_AUTH_SECRET` al ingesteld is, laat die waarde dan staan om bestaande aanmeldsessies te behouden. Bij een nieuwe installatie maakt de server zelf een sessiesleutel in het Docker-volume, dat ook je luistervoortgang bewaart. Gebruik bij een upgrade dezelfde Compose-projectnaam om dat volume te blijven gebruiken.

## Geschiedenis

De oude installatie-, diagnose- en patchscripts staan in de [herstelde snapshot](https://github.com/technoluc/storyserverNext/tree/e7745bf57474223791c1f0090128e75511a7aea8). De [recovery-status](docs/RECOVERY_STATUS.md) beschrijft welke afspeeltests toen zijn bevestigd.
