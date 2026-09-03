/* ═══════════════════════════════════════════════════════════════
   COUCHE DE DONNÉES — mon-crm-immo
   ═══════════════════════════════════════════════════════════════

   Remplace l'ancien syncToSupabase(), qui n'a jamais écrit une seule
   ligne en base. Sept causes se cumulaient ; les trois structurelles
   sont traitées ici :

     • L'app envoyait l'objet local entier (38 champs) vers une table
       qui en attendait 15. PostgREST rejetait en 400 dès la première
       colonne inconnue, et l'erreur partait dans un console.error que
       personne ne lisait.  → correspondance explicite, champ par champ.

     • Aucune suppression n'était propagée : un prospect supprimé sur
       un appareil réapparaissait au chargement suivant.
       → suppression douce (supprime_le) et propagation.

     • Tout était renvoyé toutes les 30 secondes, sans suivi des
       modifications, en écrasant le travail du collègue.
       → file d'attente persistante et horodatage par ligne.

   PRINCIPE : Supabase est la source de vérité. localStorage n'est
   qu'un cache de lecture hors ligne. Toute écriture passe par la file
   d'attente, qui survit à un rechargement de page en plein vol.

   ═══════════════════════════════════════════════════════════════ */

(function (global) {
  'use strict';

  const PREFIXE      = 'mci_';
  const CLE_FILE     = PREFIXE + 'file_attente';
  const CLE_SYNC     = PREFIXE + 'dernier_sync';
  const CLE_CACHE    = (entite) => PREFIXE + 'cache_' + entite;

  // ══════════════════════════════════════════════════════════════
  // 1. CORRESPONDANCE APP ↔ BASE
  // ══════════════════════════════════════════════════════════════
  //
  // `colonnes`  : correspondance directe, nom app → nom colonne.
  // `details`   : champs regroupés dans la colonne jsonb `details`.
  //               Ils n'ont pas de colonne propre parce qu'ils sont
  //               spécifiques à un type de prospect et n'ont jamais
  //               besoin d'être filtrés ou triés en SQL.
  // `nombres`   : champs à convertir en numérique — l'app les lit
  //               dans des champs texte, « 350 000 € » n'est pas un
  //               numeric valide.
  // `enfants`   : tableaux qui deviennent des tables filles.

  const SCHEMAS = {

    prospects: {
      table: 'prospects',
      colonnes: {
        id: 'id',
        prenom: 'prenom',
        nom: 'nom',
        email: 'email',
        tel: 'tel',
        profession: 'profession',
        prospectType: 'type',
        stage: 'etape',
        budget: 'budget',
        commission: 'commission',
        source: 'source',
        adresseClient: 'adresse_client',
        adresse: 'secteur',
        rayon: 'rayon_km',
        typeBien: 'type_bien',
        bien: 'bien',
        financement: 'financement',
        apport: 'apport',
        horizon: 'horizon',
        criteres: 'criteres',
        note: 'note',
        followUp: 'relance_le',
        perdu: 'perdu',
        motifPerte: 'motif_perte',
        createdAt: 'created_at',
      },
      details: [
        'motivationVendeur', 'dpeVendeur', 'travauxVendeur',
        'investType', 'investStructure', 'sciRegime', 'rendementVise',
        'dejaProprietaire', 'experienceInvest', 'objectifInvest',
        'accordBanque', 'mandat', 'mandatRef', 'assignedMandats',
      ],
      nombres: ['budget', 'commission', 'apport'],
      entiers: ['rayon'],
      dates:   ['followUp'],
      enfants: {
        notes:      { table: 'prospect_notes',      champs: { text: 'texte', date: 'created_at' } },
        activities: { table: 'prospect_activites',  champs: { type: 'type', note: 'note', date: 'date_activite' } },
        followups:  { table: 'prospect_relances',   champs: { titre: 'titre', date: 'echeance', done: 'faite' } },
      },
    },

    mandats: {
      table: 'mandats',
      colonnes: {
        id: 'id',
        numMandat: 'num_mandat',
        type: 'type',
        statut: 'statut',
        vendeur: 'vendeur',
        tel: 'vendeur_tel',
        bien: 'bien',
        surface: 'surface',
        pieces: 'pieces',
        adresse: 'adresse',
        ville: 'ville',
        codePostal: 'code_postal',
        prix: 'prix',
        hono: 'honoraires',
        dpe: 'dpe',
        dateSign: 'date_signature',
        dateExp: 'date_expiration',
        desc: 'note',
        portals: 'portails',
        photos: 'photos',
        vendu: 'vendu',
        venduPrix: 'vendu_prix',
        venduDate: 'vendu_le',
        venduAcquereur: 'vendu_acquereur',
        venduCommission: 'vendu_commission',
        venduNote: 'vendu_note',
        createdAt: 'created_at',
      },
      details: [],
      nombres: ['surface', 'prix', 'hono', 'venduPrix', 'venduCommission'],
      entiers: ['pieces'],
      dates:   ['dateSign', 'dateExp', 'venduDate'],
      enfants: {},   // les photos passent par Storage, cf. Fichiers
    },

    rdvs: {
      table: 'rdvs',
      colonnes: {
        id: 'id',
        type: 'type',
        titre: 'titre',
        prospect: 'avec_qui',
        prospectId: 'prospect_id',
        mandatId: 'mandat_id',
        date: 'date_rdv',
        heure: 'heure',
        duree: 'duree_min',
        adresse: 'adresse',
        note: 'note',
        lienVisio: 'lien_visio',
        googleEventId: 'google_event_id',
        googleSynced: 'google_synced',
        createdAt: 'created_at',
      },
      details: [],
      nombres: [],
      entiers: ['duree'],
      dates:   ['date'],
      enfants: {},
    },
  };

  // ══════════════════════════════════════════════════════════════
  // 2. CONVERSIONS
  // ══════════════════════════════════════════════════════════════

  /** « 350 000 € » → 350000. Renvoie null si rien d'exploitable. */
  function versNombre(v) {
    if (v === null || v === undefined || v === '') return null;
    if (typeof v === 'number') return isFinite(v) ? v : null;
    const n = parseFloat(
      String(v).replace(/\s| /g, '').replace(/[€%]/g, '').replace(',', '.')
    );
    return isFinite(n) ? n : null;
  }

  function versEntier(v) {
    const n = versNombre(v);
    return n === null ? null : Math.round(n);
  }

  /** Une date vide doit valoir null, pas '' — Postgres refuse ''. */
  function versDate(v) {
    if (!v) return null;
    const s = String(v).trim();
    return s === '' ? null : s;
  }

  function estUuid(v) {
    return typeof v === 'string' &&
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
  }

  /**
   * Objet applicatif → ligne prête pour PostgREST.
   * Les champs inconnus du schéma sont ignorés plutôt qu'envoyés :
   * c'est précisément ce qui faisait échouer chaque écriture.
   */
  function versBase(entite, obj, contexte) {
    const s = SCHEMAS[entite];
    if (!s) throw new Error('Entité inconnue : ' + entite);

    const ligne = {};

    for (const [champApp, colonne] of Object.entries(s.colonnes)) {
      if (!(champApp in obj)) continue;
      let v = obj[champApp];

      if (s.nombres.includes(champApp))      v = versNombre(v);
      else if (s.entiers.includes(champApp)) v = versEntier(v);
      else if (s.dates.includes(champApp))   v = versDate(v);
      else if (v === '')                     v = null;

      ligne[colonne] = v;
    }

    // Un identifiant hérité ('p1777922942986') n'est pas un uuid :
    // on le laisse au serveur, qui en générera un.
    if (!estUuid(ligne.id)) delete ligne.id;

    if (s.details.length) {
      const d = {};
      for (const champ of s.details) {
        if (champ in obj && obj[champ] !== '' && obj[champ] != null) d[champ] = obj[champ];
      }
      ligne.details = d;
    }

    if (contexte) {
      if (contexte.orgId) ligne.org_id = contexte.orgId;

      // _attribueA est un champ de service, absent de `colonnes` :
      // ligne.attribue_a était donc toujours vide ici, et le repli
      // sur l'utilisateur courant réattribuait le lead à quiconque
      // le sauvegardait. Un lead de Simon devenait celui du gérant
      // dès qu'il y touchait — et l'imputabilité s'effondrait en
      // silence. Le titulaire connu prime ; le repli ne sert qu'aux
      // fiches réellement nouvelles.
      if (obj._attribueA)       ligne.attribue_a = obj._attribueA;
      else if (contexte.userId) ligne.attribue_a = contexte.userId;
    }

    return ligne;
  }

  /**
   * Les tableaux enfants — notes, activités — étaient déclarés dans
   * les schémas mais jamais écrits : versBase() ne transmet que les
   * colonnes, et les enfants n'en sont pas. Une note prise sur un
   * lead vivait donc dans le seul navigateur qui l'avait saisie, et
   * le déclencheur qui horodate le premier contact ne se déclenchait
   * jamais.
   *
   * On insère uniquement ce que le serveur ne connaît pas encore. Une
   * activité est un fait daté : elle ne se modifie pas, elle s'ajoute.
   * Comparer sur (type, note, date) suffit donc à éviter les doublons
   * sans avoir à leur inventer un identifiant.
   */
  async function envoyerEnfants(sb, schema, parentId, objet) {
    if (!parentId || !estUuid(parentId)) return;

    for (const [nom, e] of Object.entries(schema.enfants || {})) {
      const locales = Array.isArray(objet[nom]) ? objet[nom] : [];
      if (!locales.length) continue;

      const { data: distantes, error } = await sb.from(e.table)
        .select('*').eq('prospect_id', parentId);
      if (error) continue;

      const empreinte = (o, champs) => Object.keys(champs)
        .map((k) => String(o[champs[k]] ?? o[k] ?? '')).join('|');

      const deja = new Set((distantes || []).map((d) => {
        return Object.values(e.champs).map((c) => String(d[c] ?? '')).join('|');
      }));

      const nouvelles = locales.filter((l) => {
        const cle = Object.keys(e.champs).map((k) => String(l[k] ?? '')).join('|');
        return !deja.has(cle);
      });
      if (!nouvelles.length) continue;

      const lignes = nouvelles.map((l) => {
        const r = { prospect_id: parentId };
        for (const [champApp, colonne] of Object.entries(e.champs)) {
          let v = l[champApp];
          if (colonne === 'date_activite' && v) v = String(v).slice(0, 10);
          if (v !== undefined && v !== '') r[colonne] = v;
        }
        return r;
      });

      await sb.from(e.table).insert(lignes);
    }
  }

  /**
   * Relit les tables filles des parents reçus. Une requête par table,
   * jamais une par parent : cinquante leads feraient cent allers-
   * retours, et l'écran attendrait.
   */
  async function lireEnfants(sb, schema, ids) {
    const par = {};
    const tables = Object.entries(schema.enfants || {});
    if (!tables.length || !ids.length) return par;

    const uuids = ids.filter(estUuid);
    if (!uuids.length) return par;

    for (const [nom, e] of tables) {
      const { data, error } = await sb.from(e.table).select('*').in('prospect_id', uuids);
      if (error || !data) continue;

      for (const ligne of data) {
        const parent = ligne.prospect_id;
        par[parent] = par[parent] || {};
        par[parent][nom] = par[parent][nom] || [];

        const o = {};
        for (const [champApp, colonne] of Object.entries(e.champs)) o[champApp] = ligne[colonne];
        par[parent][nom].push(o);
      }
    }
    return par;
  }

  /** Ligne de base → objet applicatif. Réciproque de versBase(). */
  function versApp(entite, ligne) {
    const s = SCHEMAS[entite];
    if (!s) throw new Error('Entité inconnue : ' + entite);

    const obj = {};
    for (const [champApp, colonne] of Object.entries(s.colonnes)) {
      if (colonne in ligne) obj[champApp] = ligne[colonne];
    }

    const d = ligne.details || {};
    for (const champ of s.details) {
      if (champ in d) obj[champ] = d[champ];
    }

    // Champs de service, utiles à la synchronisation et à l'affichage.
    obj._maj        = ligne.updated_at;
    obj._supprimeLe = ligne.supprime_le || null;
    obj._attribueA  = ligne.attribue_a;

    for (const nom of Object.keys(s.enfants)) obj[nom] = obj[nom] || [];

    return obj;
  }

  // ══════════════════════════════════════════════════════════════
  // 3. CACHE LOCAL
  // ══════════════════════════════════════════════════════════════

  const Cache = {
    lire(entite) {
      try { return JSON.parse(localStorage.getItem(CLE_CACHE(entite)) || '[]'); }
      catch (_) { return []; }
    },
    ecrire(entite, liste) {
      try { localStorage.setItem(CLE_CACHE(entite), JSON.stringify(liste)); }
      catch (e) { console.warn('Cache saturé pour', entite, '—', e.name); }
    },
    vider() {
      Object.keys(SCHEMAS).forEach((e) => localStorage.removeItem(CLE_CACHE(e)));
      localStorage.removeItem(CLE_SYNC);
    },
  };

  // ══════════════════════════════════════════════════════════════
  // 4. FILE D'ATTENTE
  // ══════════════════════════════════════════════════════════════
  //
  // Persistée : une fermeture d'onglet en pleine synchronisation ne
  // fait pas perdre les modifications. Chaque opération porte son
  // horodatage, ce qui permet de rejouer dans l'ordre.

  const File = {
    lire() {
      try { return JSON.parse(localStorage.getItem(CLE_FILE) || '[]'); }
      catch (_) { return []; }
    },
    ecrire(ops) {
      try { localStorage.setItem(CLE_FILE, JSON.stringify(ops)); }
      catch (e) { console.warn('File d\'attente saturée —', e.name); }
    },
    ajouter(op) {
      const ops = File.lire();
      // Une même ligne modifiée deux fois de suite ne part qu'une fois.
      const i = ops.findIndex((o) => o.entite === op.entite && o.id === op.id && o.type === op.type);
      if (i >= 0) ops[i] = op; else ops.push(op);
      File.ecrire(ops);
    },
    retirer(op) {
      File.ecrire(File.lire().filter(
        (o) => !(o.entite === op.entite && o.id === op.id && o.type === op.type)
      ));
    },
    taille() { return File.lire().length; },
  };

  // ══════════════════════════════════════════════════════════════
  // 5. DÉPÔTS
  // ══════════════════════════════════════════════════════════════

  // Organisation et utilisateur courants, posés après connexion.
  // Sans eux, aucune écriture ne peut être rattachée : org_id est NOT NULL.
  let _contexte = null;

  function definirContexte(c) { _contexte = c || null; }
  function contexteCourant() { return _contexte; }

  /**
   * Signature d'un objet, hors champs de service. Sert à repérer ce qui
   * a réellement changé : sans cela on renverrait tout à chaque
   * sauvegarde, exactement le défaut de l'ancienne synchronisation.
   */
  function signature(obj) {
    const c = {};
    for (const k of Object.keys(obj).sort()) {
      if (k === '_maj' || k === '_supprimeLe' || k === '_attribueA') continue;
      c[k] = obj[k];
    }
    return JSON.stringify(c);
  }

  function creerDepot(entite) {
    return {
      /** Tout ce qui n'est pas supprimé, depuis le cache. */
      liste() {
        return Cache.lire(entite).filter((o) => !o._supprimeLe);
      },

      trouver(id) {
        return Cache.lire(entite).find((o) => o.id === id) || null;
      },

      /** Écrit dans le cache et met en file. Ne bloque pas l'interface. */
      enregistrer(obj) {
        const liste = Cache.lire(entite);
        const i = liste.findIndex((o) => o.id === obj.id);
        obj._maj = new Date().toISOString();
        if (i >= 0) liste[i] = obj; else liste.push(obj);
        Cache.ecrire(entite, liste);
        File.ajouter({ type: 'maj', entite, id: obj.id, objet: obj, ts: obj._maj });
        return obj;
      },

      /**
       * Reçoit le tableau complet tenu par l'application et en déduit ce
       * qui a changé. L'app continue de muter ses tableaux puis d'appeler
       * saveP_() : c'est ici que ce geste devient une synchronisation
       * correcte, sans toucher aux 36 endroits qui l'appellent.
       *
       * Un identifiant disparu du tableau vaut suppression : c'est ainsi
       * que quickDel() et delProspect(), qui filtrent puis sauvegardent,
       * se retrouvent gérés sans modification.
       */
      remplacerTout(liste) {
        const cache = Cache.lire(entite);
        const avantParId = new Map(cache.map((o) => [o.id, o]));
        const idsPresents = new Set(liste.map((o) => o.id));
        const t = new Date().toISOString();
        let modifies = 0, supprimes = 0;

        for (const obj of liste) {
          const avant = avantParId.get(obj.id);
          if (!avant || signature(avant) !== signature(obj)) {
            obj._maj = t;
            File.ajouter({ type: 'maj', entite, id: obj.id, objet: obj, ts: t });
            modifies++;
          } else {
            obj._maj = avant._maj;
          }
        }

        // Les pierres tombales restent dans le cache mais pas dans le
        // tableau applicatif : l'utilisateur ne doit plus les voir.
        const tombes = [];
        for (const avant of cache) {
          if (idsPresents.has(avant.id)) continue;
          if (!avant._supprimeLe) {
            avant._supprimeLe = t;
            File.ajouter({ type: 'suppr', entite, id: avant.id, ts: t });
            supprimes++;
          }
          tombes.push(avant);
        }

        Cache.ecrire(entite, liste.concat(tombes));
        return { modifies, supprimes };
      },

      /**
       * Suppression douce. La ligne reste, marquée, pour que les autres
       * appareils apprennent la suppression au lieu de la ressusciter.
       */
      supprimer(id) {
        const liste = Cache.lire(entite);
        const i = liste.findIndex((o) => o.id === id);
        if (i < 0) return false;
        liste[i]._supprimeLe = new Date().toISOString();
        Cache.ecrire(entite, liste);
        File.ajouter({ type: 'suppr', entite, id, ts: liste[i]._supprimeLe });
        return true;
      },
    };
  }

  // ══════════════════════════════════════════════════════════════
  // 6. SYNCHRONISATION
  // ══════════════════════════════════════════════════════════════

  let _enCours = false;

  async function synchroniser(sb, contexte) {
    contexte = contexte || _contexte;
    if (_enCours) return { ignore: true };
    if (!sb || !contexte || !contexte.orgId) return { horsLigne: true };

    _enCours = true;
    const bilan = { envoyes: 0, recus: 0, erreurs: [] };

    try {
      // ── Envoi : on rejoue la file dans l'ordre ──
      for (const op of File.lire()) {
        const s = SCHEMAS[op.entite];
        try {
          if (op.type === 'suppr') {
            const { error } = await sb.from(s.table)
              .update({ supprime_le: op.ts }).eq('id', op.id);
            if (error) throw error;
          } else {
            const ligne = versBase(op.entite, op.objet, contexte);
            const { data, error } = await sb.from(s.table)
              .upsert(ligne, { onConflict: 'id' }).select('id').single();
            if (error) throw error;
            // Un identifiant hérité a été remplacé par un uuid serveur :
            // on répercute dans le cache pour ne pas créer de doublon.
            if (data && data.id !== op.id) remplacerId(op.entite, op.id, data.id);
            await envoyerEnfants(sb, s, data ? data.id : op.id, op.objet);
          }
          File.retirer(op);
          bilan.envoyes++;
        } catch (e) {
          bilan.erreurs.push({ op: op.type, entite: op.entite, id: op.id, message: e.message });
          // On garde l'opération en file : elle repartira au prochain tour.
        }
      }

      // ── Réception : uniquement ce qui a changé depuis la dernière fois ──
      const depuis = localStorage.getItem(CLE_SYNC);
      const maintenant = new Date().toISOString();

      for (const [entite, s] of Object.entries(SCHEMAS)) {
        let q = sb.from(s.table).select('*');
        if (depuis) q = q.gt('updated_at', depuis);
        const { data, error } = await q;
        if (error) { bilan.erreurs.push({ entite, message: error.message }); continue; }
        if (!data || !data.length) continue;

        // Les tables filles ne portent pas d'updated_at : elles sont
        // relues pour les parents reçus. Sans cela, versApp() rendrait
        // un objet aux enfants vides, et l'affectation ci-dessous
        // effacerait les notes et les tentatives d'appel prises
        // localement — ce qui donnait l'impression qu'elles ne
        // s'enregistraient pas.
        const enfants = await lireEnfants(sb, s, data.map((l) => l.id));

        const liste = Cache.lire(entite);
        for (const ligne of data) {
          const obj = versApp(entite, ligne);
          const recus = enfants[ligne.id];
          if (recus) for (const nom of Object.keys(recus)) obj[nom] = recus[nom];

          const i = liste.findIndex((o) => o.id === obj.id);
          if (i < 0) { liste.push(obj); bilan.recus++; continue; }

          // Conflit : la version la plus récente gagne, mais on le signale.
          const localPlusRecent = liste[i]._maj && liste[i]._maj > obj._maj;
          if (!localPlusRecent) {
            // Une modification locale non encore envoyée ne doit pas
            // disparaître parce que le serveur a répondu entre-temps.
            for (const nom of Object.keys(s.enfants || {})) {
              const local = Array.isArray(liste[i][nom]) ? liste[i][nom] : [];
              if (local.length > (obj[nom] || []).length) obj[nom] = local;
            }
            liste[i] = obj;
            bilan.recus++;
          }
        }
        Cache.ecrire(entite, liste);
      }

      if (!bilan.erreurs.length) localStorage.setItem(CLE_SYNC, maintenant);
      return bilan;

    } finally {
      _enCours = false;
    }
  }

  /**
   * Le serveur a généré un uuid pour remplacer un identifiant hérité.
   * On répercute dans le cache ET dans la file : une suppression mise
   * en attente avant le premier envoi viserait sinon l'ancien
   * identifiant, et ne supprimerait rien.
   */
  function remplacerId(entite, ancien, nouveau) {
    const liste = Cache.lire(entite);
    const i = liste.findIndex((o) => o.id === ancien);
    if (i >= 0) { liste[i].id = nouveau; Cache.ecrire(entite, liste); }

    const ops = File.lire();
    let touche = false;
    for (const op of ops) {
      if (op.entite === entite && op.id === ancien) {
        op.id = nouveau;
        if (op.objet) op.objet.id = nouveau;
        touche = true;
      }
    }
    if (touche) File.ecrire(ops);
  }

  /** Premier chargement : on repart de zéro depuis le serveur. */
  async function chargerTout(sb, contexte) {
    contexte = contexte || _contexte;
    localStorage.removeItem(CLE_SYNC);
    Object.keys(SCHEMAS).forEach((e) => Cache.ecrire(e, []));
    return synchroniser(sb, contexte);
  }

  // ══════════════════════════════════════════════════════════════
  // 7. SURFACE PUBLIQUE
  // ══════════════════════════════════════════════════════════════

  const Donnees = {
    prospects: creerDepot('prospects'),
    mandats:   creerDepot('mandats'),
    rdvs:      creerDepot('rdvs'),

    synchroniser,
    chargerTout,
    definirContexte,
    contexte: contexteCourant,
    enAttente: () => File.taille(),
    vider: Cache.vider,

    /**
     * Efface tout : cache, curseur de synchronisation ET file d'attente.
     * Cache.vider() laissait la file intacte, ce qui suffisait au
     * débogage mais pas à une déconnexion — les modifications non
     * envoyées de l'un seraient reparties sous la session du suivant.
     */
    viderTout() {
      Cache.vider();
      localStorage.removeItem(CLE_FILE);
      _contexte = null;
    },

    // Exposés pour les tests et le débogage.
    _remplacerId: remplacerId,
    _signature: signature,
    _versBase: versBase,
    _versApp:  versApp,
    _schemas:  SCHEMAS,
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = Donnees;
  else global.Donnees = Donnees;

})(typeof globalThis !== 'undefined' ? globalThis : this);
