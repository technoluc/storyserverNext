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

De server haalt bij het starten automatisch luisterboekmetadata op bij Nextory en bewaart die in het Docker-volume. De bibliotheek kan bij een eerste start kort leeg zijn. Zoeken gebruikt Nextory live, en als je een genrecollectie opent kan de server meer titels aan de lokale index toevoegen. De bibliotheek groeit mee met die zoek- en ontdekacties. Je hoeft geen boek-ID’s in te vullen.

## Afspelen in AudioBooth

AudioBooth krijgt standaard een virtuele M4B voor ieder boek. De server maakt de audio op aanvraag met één FFmpeg-worker en deelt maximaal 16 MiB aan audiocache tussen alle sessies, met maximaal 8 MiB per sessie. Bij ruimtegebrek verdwijnen de minst recent gebruikte audioblokken uit de cache. Een nog geldige sessie kan ze opnieuw genereren. Als een boek niet als M4B kan worden voorbereid, gebruikt de server de bestaande HLS-route. Andere clients blijven HLS gebruiken.

Heb je eerder `NEXTORY_TEST_VIRTUAL_M4B_BOOK` in je `.env` gezet, verwijder dan die regel of zet de waarde op `all` om alle boeken te gebruiken.

## Bestaande installatie bijwerken

Voeg de twee Nextory-variabelen toe aan je bestaande `.env` en behoud je huidige serverwachtwoord. Als `TEST_AUTH_SECRET` al ingesteld is, laat die waarde dan staan om bestaande aanmeldsessies te behouden. Bij een nieuwe installatie maakt de server zelf een sessiesleutel in het Docker-volume, dat ook je luistervoortgang bewaart. Gebruik bij een upgrade dezelfde Compose-projectnaam om dat volume te blijven gebruiken.

## Geschiedenis

De oude installatie-, diagnose- en patchscripts staan in de [herstelde snapshot](https://github.com/technoluc/storyserverNext/tree/e7745bf57474223791c1f0090128e75511a7aea8). De [recovery-status](docs/RECOVERY_STATUS.md) beschrijft welke afspeeltests toen zijn bevestigd.
