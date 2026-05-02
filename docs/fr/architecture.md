# Infrastructure MVP Aegis AI

Ce dépôt fait office de cœur névralgique **GitOps** pour le paramétrage d'Aegis AI. Soutenu par la puissance d'ArgoCD, `Aegis-AI-Infra` déploie l'armada complète de microservices sur le cluster Kubernetes cible (`aegis-system`), construisant le maillage réseau et les contrôles d'accès de manière implicite.

## Environnement : MVP (Successeur de Pre-Alpha)
Nous avons officiellement abandonné la nomenclature `pre-alpha` pour endosser le sigle et la solidité de la release `mvp`. L'architecture de base s'appuie sur le chart Helm souverain `aegis-service`, itérativement appliqué à notre stack de microservices.

### Topologie Réseau Zero Trust
Nous barricadons rigoureusement notre cluster interne face aux sandboxes compromises et mouvements latéraux grâce aux **Cilium Network Policies** :
- **Isolement Gateway** : L'API opère de façon aveugle. Incapable de commander PostgreSQL ou Temporal. Egress toléré strictement vers le port gRPC cible du `brain`.
- **Confinement Base de Données et Files** : Temporal et PostgreSQL (les garants de l'état du système) sont ceinturés par une `CiliumNetworkPolicy` balayant toute tentative d'entrée parasite. Ils n'acceptent de flux qu'en provenance formelle de l'identifiant de namespace `brain-mvp`.
- **Endiguement Sandbox** : Toute image déployée étiquetée `app: vulnerable-target` tombe sous le joug d'une `CiliumClusterwideNetworkPolicy`. Le trafic réseau latéral y est anéanti (seul la réception de tirs du Pentest Worker et l'extraction de payloads via Internet y sont approuvés).

## Chiffrement & mTLS (mutual TLS)

Pour protéger l'intégrité des échanges entre le Gateway, le Brain et les Workers, le cluster force l'utilisation de **mTLS**.
- Chaque service possède un certificat signé par l'Autorité de Certification (CA) interne d'Aegis.
- Le Brain refuse systématiquement toute connexion gRPC qui ne présente pas un certificat client valide et approuvé.
- Les secrets TLS sont gérés de manière sécurisée via des `Kubernetes Secrets` injectés dynamiquement dans les pods lors du démarrage.

## Remises Continues (CD)
ArgoCD centralise sa vision sur l'arbre de manifeste `mvp` localisé au chemin `kubernetes/envs/mvp/kustomization.yaml`. Une modification poussée vers ce dépôt est instantanément reflétée sur le déploiement principal en staging.
