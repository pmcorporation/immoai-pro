// localStorage minimal : la couche s'en sert pour le cache et la file.
const _mem = {};
globalThis.localStorage = {
  getItem: (k) => (k in _mem ? _mem[k] : null),
  setItem: (k, v) => { _mem[k] = String(v); },
  removeItem: (k) => { delete _mem[k]; },
};

const D = require('./donnees.js');
let ok = 0, ko = 0;
const t = (nom, cond, detail) => {
  if (cond) { ok++; console.log('  ✓', nom); }
  else { ko++; console.log('  ✗', nom, detail !== undefined ? '→ ' + JSON.stringify(detail) : ''); }
};

// Un prospect tel que l'app le produit vraiment (38 champs)
const prospect = {
  id: 'p1777922942986', prenom: 'Marie', nom: 'Dubois',
  tel: '0612345678', email: 'marie@example.fr', prospectType: 'vendeur',
  adresseClient: '12 rue de la Paix', profession: 'Cadre',
  motivationVendeur: 'Mutation', dpeVendeur: 'D', travauxVendeur: 'Aucun',
  investType: '', investStructure: '', sciRegime: '', rendementVise: '',
  dejaProprietaire: 'oui', experienceInvest: '', objectifInvest: '',
  assignedMandats: [], budget: '350 000 €', commission: 12000,
  source: 'Bouche à oreille', adresse: 'Lyon 6e', rayon: '10',
  typeBien: 'Appartement', bien: 'T4', financement: 'Comptant',
  apport: '', accordBanque: '', horizon: '3 mois',
  criteres: { pieces: 4, exterieur: true },
  mandat: null, stage: 'estimation',
  notes: [{ text: 'Rappeler lundi', date: '2026-08-25' }],
  activities: [], followups: [], documents: [], mandatRef: null,
  createdAt: '2026-08-25', followUp: '',
};

const ctx = { orgId: 'aaaaaaaa-1111-2222-3333-444444444444',
              userId: 'bbbbbbbb-1111-2222-3333-444444444444' };
const ligne = D._versBase('prospects', prospect, ctx);

console.log('\n── Conversion vers la base ──');
// L'identifiant est désormais fabriqué côté client. Laisser le serveur
// le générer rendait l'envoi non rejouable : une réponse perdue après
// l'insertion faisait créer un second exemplaire à chaque tentative.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
t('identifiant hérité remplacé par un uuid, pas supprimé',
  typeof ligne.id === 'string' && UUID.test(ligne.id), ligne.id);
t('l\'envoi est rejouable : deux conversions donnent des uuid valides',
  UUID.test(D._versBase('prospects', prospect, null).id), 'non');
t('« 350 000 € » devient 350000', ligne.budget === 350000, ligne.budget);
t('rayon « 10 » devient l\'entier 10', ligne.rayon_km === 10, ligne.rayon_km);
t('date vide devient null, pas \'\'', ligne.relance_le === null, ligne.relance_le);
t('apport vide devient null', ligne.apport === null, ligne.apport);
t('prospectType → colonne type', ligne.type === 'vendeur', ligne.type);
t('stage → colonne etape', ligne.etape === 'estimation', ligne.etape);
t('adresseClient → adresse_client', ligne.adresse_client === '12 rue de la Paix');
t('adresse → secteur', ligne.secteur === 'Lyon 6e');
t('org_id injecté', ligne.org_id === ctx.orgId);
t('attribue_a injecté', ligne.attribue_a === ctx.userId);
t('champs spécifiques regroupés dans details',
  ligne.details.motivationVendeur === 'Mutation' && ligne.details.dejaProprietaire === 'oui',
  ligne.details);
t('details ne garde pas les champs vides', !('investType' in ligne.details), ligne.details);

console.log('\n── Aucun champ inconnu envoyé (la cause du rejet 400) ──');
const colonnesReelles = new Set([
  'id','org_id','attribue_a','cree_par','prenom','nom','email','tel','profession',
  'type','etape','perdu','motif_perte','budget','commission','source',
  'adresse_client','secteur','rayon_km','type_bien','bien','criteres',
  'financement','apport','horizon','details','note','relance_le',
  'created_at','updated_at','supprime_le',
]);
const intrus = Object.keys(ligne).filter((c) => !colonnesReelles.has(c));
t('aucune colonne inexistante', intrus.length === 0, intrus);
t('les tableaux enfants ne partent pas dans la ligne',
  !('notes' in ligne) && !('activities' in ligne) && !('documents' in ligne));

console.log('\n── Aller-retour ──');
const retour = D._versApp('prospects', {
  ...ligne, id: 'cccccccc-1111-2222-3333-444444444444',
  updated_at: '2026-08-25T10:00:00Z', supprime_le: null,
});
t('prénom conservé', retour.prenom === 'Marie');
t('budget revient en nombre', retour.budget === 350000, retour.budget);
t('details redéployés en champs plats', retour.motivationVendeur === 'Mutation');
t('type revient en prospectType', retour.prospectType === 'vendeur');
t('tableaux enfants réinitialisés', Array.isArray(retour.notes));

console.log('\n── Mandat : les valeurs qui auraient été rejetées ──');
const m = D._versBase('mandats', {
  id: 'm1777962620408', type: 'coexclu', statut: 'actif',
  vendeur: 'M. Martin', tel: '0698765432', prix: '450 000',
  hono: '18 000', surface: '85,5', pieces: '4', dateSign: '2026-05-01',
  dateExp: '', dpe: 'D', desc: 'Beau T4', portals: {},
  vendu: false, venduPrix: '', venduDate: '', venduAcquereur: '',
}, ctx);
t('type « coexclu » transmis tel quel', m.type === 'coexclu', m.type);
t('« 85,5 » devient 85.5 (virgule décimale)', m.surface === 85.5, m.surface);
t('« 450 000 » devient 450000', m.prix === 450000, m.prix);
t('tel du vendeur → vendeur_tel', m.vendeur_tel === '0698765432');
t('desc → note', m.note === 'Beau T4');
t('date d\'expiration vide → null', m.date_expiration === null, m.date_expiration);

console.log('\n── RDV ──');
const r = D._versBase('rdvs', {
  id: 'r1', type: 'visite', titre: 'Visite T4',
  prospect: 'Marie Dubois', date: '2026-08-26', heure: '14:30',
  adresse: 'Lyon', note: '', duree: '45',
}, ctx);
t('saisie libre → avec_qui', r.avec_qui === 'Marie Dubois');
t('date → date_rdv', r.date_rdv === '2026-08-26');
t('durée en entier', r.duree_min === 45, r.duree_min);
t('note vide → null', r.note === null);

console.log('\n── Différentiel : ce qui part vraiment en file d\'attente ──');
const file = () => JSON.parse(localStorage.getItem('mci_file_attente') || '[]');
const videFile = () => localStorage.setItem('mci_file_attente', '[]');

const p1 = { id: 'u1', prenom: 'Marie', nom: 'Dubois', stage: 'contact' };
const p2 = { id: 'u2', prenom: 'Jean',  nom: 'Martin', stage: 'rdv' };

videFile();
D.prospects.remplacerTout([p1, p2]);
t('deux créations mises en file', file().length === 2, file().length);

videFile();
D.prospects.remplacerTout([p1, p2]);
t('aucun changement → file vide (plus de renvoi permanent)', file().length === 0, file());

videFile();
p2.stage = 'estimation';
D.prospects.remplacerTout([p1, p2]);
const f = file();
t('seul le modifié repart', f.length === 1 && f[0].id === 'u2', f);

videFile();
D.prospects.remplacerTout([p1]);          // u2 retiré du tableau, comme le fait quickDel()
const g = file();
t('un id disparu du tableau vaut suppression',
  g.length === 1 && g[0].type === 'suppr' && g[0].id === 'u2', g);

t('la suppression n\'est pas rendue à l\'application',
  D.prospects.liste().map((o) => o.id).join() === 'u1', D.prospects.liste().map((o) => o.id));

t('mais la pierre tombale reste en cache pour être propagée',
  JSON.parse(localStorage.getItem('mci_cache_prospects')).some((o) => o.id === 'u2' && o._supprimeLe));

videFile();
D.prospects.remplacerTout([p1]);
t('une suppression déjà propagée ne repart pas', file().length === 0, file());

console.log('\n── Contexte ──');
D.definirContexte({ orgId: ctx.orgId, userId: ctx.userId });
t('contexte mémorisé', D.contexte().orgId === ctx.orgId);



console.log('\n── Création puis suppression avant la première synchro ──');
(() => {
  localStorage.setItem('mci_file_attente', '[]');
  localStorage.setItem('mci_cache_prospects', '[]');

  const tmp = { id: 'p1777900000000', prenom: 'Ephemere', nom: 'Test' };
  D.prospects.remplacerTout([tmp]);       // création
  D.prospects.remplacerTout([]);          // suppression immédiate

  const avant = JSON.parse(localStorage.getItem('mci_file_attente'));
  t('les deux opérations visent l\'identifiant hérité',
    avant.length === 2 && avant.every((o) => o.id === 'p1777900000000'), avant.map((o) => o.id));

  // Le serveur répond avec un uuid : la file doit suivre.
  D._remplacerId('prospects', 'p1777900000000', 'dddddddd-1111-2222-3333-444444444444');
  const apres = JSON.parse(localStorage.getItem('mci_file_attente'));
  t('la suppression en attente vise désormais l\'uuid du serveur',
    apres.every((o) => o.id === 'dddddddd-1111-2222-3333-444444444444'), apres.map((o) => o.id));
  t('l\'objet en file porte aussi le nouvel identifiant',
    apres.find((o) => o.type === 'maj').objet.id === 'dddddddd-1111-2222-3333-444444444444');
})();

// ══════════════════════════════════════════════════════════════
// L'ATTRIBUTION NE CHANGE PAS DE MAIN À LA SAUVEGARDE
// ══════════════════════════════════════════════════════════════
// Le repli sur l'utilisateur courant réattribuait tout lead sauvegardé
// à celui qui le sauvegardait : un lead de Simon devenait celui du
// gérant dès qu'il y touchait. Toute la traçabilité en dépend.
(function () {
  console.log('\n▸ Attribution');

  const SIMON  = 'aaaaaaaa-1111-2222-3333-444444444444';
  const GERANT = 'bbbbbbbb-1111-2222-3333-444444444444';
  const ctx = { orgId: 'cccccccc-1111-2222-3333-444444444444', userId: GERANT };

  const leadDeSimon = { id: 'eeeeeeee-1111-2222-3333-444444444444',
                        prenom: 'Céline', nom: 'Ravier', stage: 'nouveau',
                        _attribueA: SIMON };
  const l1 = D._versBase('prospects', leadDeSimon, ctx);
  t('un lead attribué à Simon le reste quand le gérant sauvegarde',
    l1.attribue_a === SIMON, l1.attribue_a);

  const ficheNeuve = { id: 'ffffffff-1111-2222-3333-444444444444',
                       prenom: 'Nouveau', nom: 'Contact', stage: 'contact' };
  const l2 = D._versBase('prospects', ficheNeuve, ctx);
  t('une fiche sans titulaire revient à celui qui la crée',
    l2.attribue_a === GERANT, l2.attribue_a);

  const sansContexte = D._versBase('prospects', leadDeSimon, null);
  t('sans contexte, aucune attribution n\'est inventée',
    sansContexte.attribue_a === undefined, sansContexte.attribue_a);
})();

// ══════════════════════════════════════════════════════════════
// LES ENFANTS NE POLLUENT PAS LA LIGNE DU PARENT
// ══════════════════════════════════════════════════════════════
// Les activités partent par leur propre table. Si elles se glissaient
// dans la ligne du prospect, PostgREST rejetterait l'envoi entier.
(function () {
  console.log('\n▸ Tables filles');

  const avecEnfants = {
    id: '11111111-aaaa-bbbb-cccc-dddddddddddd',
    prenom: 'Thomas', nom: 'Girard', stage: 'nouveau',
    activities: [{ type: 'call', note: 'Pas de réponse', date: '2026-09-02' }],
    notes: [{ text: 'Rappeler ce soir', date: '2026-09-02' }],
  };
  const ligne = D._versBase('prospects', avecEnfants, null);
  t('le tableau des activités ne part pas dans la ligne du prospect',
    !('activities' in ligne) && !('activites' in ligne), Object.keys(ligne));
  t('le tableau des notes non plus',
    !('notes' in ligne), Object.keys(ligne));
})();

// ══════════════════════════════════════════════════════════════
// LES DATES FRANÇAISES NE DOIVENT PLUS PARTIR TELLES QUELLES
// ══════════════════════════════════════════════════════════════
// L'application écrit ses échéances en jj/mm/aaaa. Envoyées ainsi dans
// une colonne date, elles étaient rejetées — ou pire, acceptées avec le
// jour et le mois inversés jusqu'au 12 du mois, ce qui décalait
// silencieusement les relances sans que personne ne le voie.
(function () {
  console.log('\n▸ Dates');

  t('le jj/mm/aaaa français devient de l\'ISO',
    D._versIso('25/12/2026') === '2026-12-25', D._versIso('25/12/2026'));

  // Le cas qui rendait le défaut invisible : avant le 13, la date
  // inversée reste une date valide, donc personne ne voit l'erreur.
  t('03/09 est le 3 septembre, pas le 9 mars',
    D._versIso('03/09/2026') === '2026-09-03', D._versIso('03/09/2026'));

  t('une date déjà ISO est laissée intacte',
    D._versIso('2026-09-03') === '2026-09-03', D._versIso('2026-09-03'));

  t('un horodatage complet est ramené au jour',
    D._versIso('2026-09-03T14:32:11.000Z') === '2026-09-03', D._versIso('2026-09-03T14:32:11.000Z'));

  // Rendre null plutôt qu'une valeur douteuse : une échéance fausse est
  // pire qu'une échéance absente, parce qu'on lui fait confiance.
  t('une saisie illisible rend null, pas une date inventée',
    D._versIso('la semaine prochaine') === null, D._versIso('la semaine prochaine'));
  t('une valeur vide rend null',
    D._versIso('') === null && D._versIso(null) === null);
})();

// ══════════════════════════════════════════════════════════════
// LES RELANCES DOIVENT ATTEINDRE LEUR COLONNE
// ══════════════════════════════════════════════════════════════
// L'application pousse { title, date, done }. Le schéma attendait
// « titre » : la colonne partait vide, l'insertion était rejetée, et
// l'erreur n'était pas lue. Aucune relance n'a jamais atteint la base.
(function () {
  console.log('\n▸ Relances');
  const c = D._schemas.prospects.enfants.followups.champs;
  t('le champ applicatif « title » vise la colonne « titre »',
    c.title === 'titre', c);
  t('la date vise « echeance »', c.date === 'echeance', c);
})();

console.log(`\n${ok} réussis, ${ko} échoués`);
process.exit(ko ? 1 : 0);
