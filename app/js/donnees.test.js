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
t('identifiant hérité écarté (le serveur génère l\'uuid)', !('id' in ligne), ligne.id);
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

console.log(`\n${ok} réussis, ${ko} échoués`);
process.exit(ko ? 1 : 0);
