# Physalis — actions de publication mobile

Actions GitHub pour publier une app iOS (TestFlight / App Store) ou Android
(Google Play) avec le matériel de signature détenu par
[Physalis](https://physalis.cloud), **sans aucun secret GitHub** : chaque étape
s'authentifie auprès de Physalis par le jeton OIDC du job.

Physalis ne construit pas l'app et ne stocke pas le binaire : votre CI
construit et téléverse directement chez Apple ou Google. Physalis sert le
matériel, le numéro de build, et tient le registre des livraisons.

## Les briques

| Action | Rôle |
|---|---|
| `credentials` | Récupère le matériel de signature de l'app, le **vérifie avant tout build** (empreintes, plateforme, profil ↔ bundle id, `.p12`, alias du keystore) et sert le numéro de build. |
| `env` | Écrit les variables de build d'un environnement (par défaut les `VITE_*`) dans un fichier `.env`. Pour les apps hybrides. |
| `ios-release` | Keychain temporaire, signature manuelle, archive, **contrôle des entitlements push du binaire signé**, upload TestFlight ou App Store. |
| `android-release` | AAB signé par propriétés gradle (rien n'est écrit dans le dépôt), upload sur une piste Google Play. |
| `report` | Signale l'issue au registre de livraisons de Physalis, puis efface le matériel du runner. À appeler avec `if: always()`. |

Entre `credentials` et `*-release`, vos propres étapes construisent l'app
(`npm run build`, `npx cap sync`, personnalisations du projet natif) : les
actions ne présument rien de votre projet.

## Exemple (iOS, Capacitor avec `ios/` versionné)

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  release:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - uses: physalis-cloud/mobile-actions/credentials@v1
        with: { app: com.exemple.monapp, platform: ios }
      - uses: physalis-cloud/mobile-actions/env@v1
        with: { project: mon-projet, output: .env.production }
      - run: npm ci && npm run build && npx cap sync ios
      - uses: physalis-cloud/mobile-actions/ios-release@v1
        with: { scheme: App, project-dir: ios/App, version: pbxproj, expect-push: "true" }
      - uses: physalis-cloud/mobile-actions/report@v1
        if: always()
```

Workflows complets dans [`examples/`](examples/) :
[iOS `ios/` versionné](examples/release-ios-capacitor-versioned.yml),
[iOS `ios/` régénéré](examples/release-ios-capacitor-regenerated.yml),
[Android](examples/release-android-capacitor.yml).

## Prérequis côté Physalis

1. Déploiement mobile activé sur le projet, application créée avec son matériel
   (onglet **Mobile**). « Vérifier le matériel » contrôle tout avant le premier
   run.
2. Une **policy mobile** sur `(dépôt, fichier de workflow, branche)` → l'app.
3. Pour une app hybride, une **policy serveur** sur le même triplet →
   l'environnement qui fournit les `VITE_*`.

Le workflow doit déclarer `permissions: id-token: write`.

Guides pas à pas : *Publier une app Android sur Google Play* et *Publier une
app iOS sur l'App Store*, dans la documentation Physalis.

## Pourquoi des actions et pas un workflow réutilisable

Une action composite s'exécute dans le job qui l'appelle : le jeton OIDC
désigne **votre** workflow, celui que la policy Physalis connaît. Un workflow
réutilisable (`workflow_call`) aurait substitué le sien dans le claim
`job_workflow_ref`, et toutes les policies auraient vu le même workflow.

## Entrées principales

### `credentials`

| Entrée | Défaut | |
|---|---|---|
| `app` | — | bundleId / applicationId déclaré dans Physalis |
| `platform` | — | `ios` ou `android` ; un bundle d'une autre plateforme fait échouer |
| `signing` | `manual` | iOS : `automatic` = seule la clé d'API App Store Connect est servie (voir ci-dessous) |
| `physalis-url` | `https://vault.physalis.cloud` | instance (self-host : la vôtre) |
| `audience` | hôte de `physalis-url` | audience OIDC attendue |

Sorties : `build-number`, `version-name` (aussi exposés en `BUILD_NUMBER` /
`VERSION_NAME` pour les étapes suivantes).

### `ios-release`

| Entrée | Défaut | |
|---|---|---|
| `scheme` | — | scheme Xcode (`App` pour Capacitor) |
| `project-dir` | `ios/App` | dossier du `.xcodeproj` |
| `version` | `info-plist` | `info-plist` (valeurs littérales, `ios/` régénéré), `pbxproj` (`$(CURRENT_PROJECT_VERSION)`, `ios/` versionné), `agvtool` (natif Apple Generic), `none` |
| `expect-push` | `false` | `true` : échec **avant l'upload** si le binaire signé n'a pas `aps-environment=production` |
| `destination` | `testflight` | `testflight`, `appstore` (binaire seul, pas d'envoi en revue), `none` |

### `android-release`

| Entrée | Défaut | |
|---|---|---|
| `project-dir` | `android` | projet gradle |
| `version` | `gradle` | substitution relue dans `build.gradle(.kts)`, ou `none` |
| `track` | `internal` | `internal`, `alpha`, `beta`, `production` |
| `first-release` | `false` | `true` au tout premier envoi d'un package en brouillon |

> ⚠️ **Le premier `.aab` doit être signé avec le keystore enregistré dans
> Physalis** : Play App Signing enrôle la clé d'upload sur la première release.
> Le plus sûr : le laisser partir par ce pipeline avec `first-release: true`.

## Signature automatique (iOS, apps à extensions)

`ios-release` signe à la main avec **un** certificat et **un** profil. Une app
qui embarque une extension (remplissage automatique, widget, notifications
enrichies, partage) a besoin d'un profil par cible. Dans ce cas :

- dans Physalis, l'application ne porte que la **clé d'API App Store Connect**
  (rôle **Admin**, pour que Xcode puisse créer certificat et profils), son
  identifiant, l'Issuer ID, et le **Team ID** dans « Team ID / éditeur » ;
- `credentials` avec `signing: automatic` pose `ASC_KEY_PATH`, `ASC_KEY_ID`,
  `ASC_ISSUER_ID`, `TEAM_ID` et `BUILD_NUMBER` ;
- **recommandé** : un certificat de distribution (`.p12` + mot de passe) dans
  l'application — le bouton « Générer le matériel de signature » de Physalis
  le fabrique à partir de la seule clé d'API. `credentials` l'importe alors
  dans un keychain temporaire et l'export signe avec lui. Sans lui, Xcode
  signe avec le certificat *Cloud Managed* d'Apple, et App Store Connect a
  rejeté de tels envois (« Invalid Signature. Code failed to satisfy
  specified code requirement(s) »). Le profil généré avec n'est pas utilisé :
  Xcode crée les siens, un par cible ;
- le workflow archive et envoie lui-même, `ios-release` n'est pas utilisé :

```yaml
      - uses: physalis-cloud/mobile-actions/credentials@v1
        with: { app: com.exemple.monapp, platform: ios, signing: automatic }
      - run: |
          xcodebuild archive -project ios/App/App.xcodeproj -scheme App \
            -configuration Release -destination generic/platform=iOS \
            -archivePath "$RUNNER_TEMP/App.xcarchive" \
            -allowProvisioningUpdates \
            -authenticationKeyPath "$ASC_KEY_PATH" \
            -authenticationKeyID "$ASC_KEY_ID" \
            -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
            DEVELOPMENT_TEAM="$TEAM_ID" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
          # puis xcodebuild -exportArchive avec method app-store-connect et
          # destination upload (mêmes options d'authentification)
      - uses: physalis-cloud/mobile-actions/report@v1
        if: always()
        with:
          track: testflight
          status: ${{ job.status == 'success' && 'uploaded' || 'failed' }}
```

Exemple complet : le dépôt public
[`physalis-cloud/physalis-mobile`](https://github.com/physalis-cloud/physalis-mobile),
qui publie l'app Physalis elle-même de cette façon.

## Notifications push (iOS)

Le cas silencieux : le profil autorise le push, mais l'app n'embarque pas
d'`App.entitlements` qui le demande (`npx cap add` n'en crée aucun). Le build,
l'upload et la revue passent ; les notifications n'arrivent jamais.
`expect-push: "true"` relit les entitlements du binaire **signé** et échoue
avant l'upload. Sans cette entrée, l'action se contente d'avertir.

## Versions

Épinglez une version majeure (`@v1`) ou, pour une garantie stricte, le SHA
d'un commit. Les correctifs arrivent sur `v1` sans changement de votre côté.

## Licence

MIT
