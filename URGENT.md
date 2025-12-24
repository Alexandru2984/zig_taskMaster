1. Analiza Codului și Probleme Identificate
A. Securitate (Critic)
Validarea Sesiunii Incompletă:

În src/db/surreal.zig, funcția validateSession conține un comentariu îngrijorător: // TODO: Check expiration (for now, just return user_id).

Impact: Token-urile de sesiune nu expiră niciodată efectiv pe server. Chiar dacă un token e vechi de un an, utilizatorul rămâne logat.

Secret Hardcodat:

În src/services/auth.zig, secretul pentru hash-urile vechi este hardcodat: const SECRET = "zig-task-manager-secret-2024";.

Impact: Dacă acest cod devine public (cum e pe GitHub), oricine poate genera hash-uri valide pentru sistemul "legacy". Acest secret trebuie să fie în variabile de mediu (.env).

Parsare Manuală JSON vs. Structuri:

În src/db/surreal.zig (ex: getTaskOwner, validateSession), încerci să extragi datele făcând "string search" manual: std.mem.indexOf(u8, result, "\"user_id\":\"").

Impact: Extrem de fragil. Dacă SurrealDB schimbă formatarea JSON (ex: adaugă spații), codul se strică. De asemenea, poate duce la vulnerabilități dacă un utilizator reușește să injecteze caractere care seamănă cu JSON-ul în câmpuri.

SQL Injection (Parțial Mitigat dar Riscant):

Deși folosești o funcție escape, construiești query-urile prin interpolare de string-uri: std.fmt.allocPrint(..., "SELECT ... WHERE email = \"{s}\"", ...).

Soluție: SurrealDB suportă parametri ($variabila). Este mult mai sigur să trimiți query-ul cu placeholdere și variabilele separat, decât să le lipești într-un string.

B. Performanță și Managementul Resurselor
Rate Limiter - Lipsă Cleanup:

src/util/rate_limiter.zig are o funcție cleanup, dar aceasta nu pare să fie apelată automat nicăieri în src/main.zig.

Impact: HashMap-ul care ține minte IP-urile va crește la infinit până când serverul rămâne fără memorie (Memory Leak). Ai nevoie de un thread separat care să ruleze cleanup periodic.

Alocări excesive:

Se folosește foarte mult std.fmt.allocPrint pentru orice operațiune mică de DB. În Zig, e preferabil să folosești un buffer pe stivă sau un std.ArrayList reutilizabil pentru a reduce presiunea pe allocator.

C. Arhitectură
Erori Repetitive: În src/handlers/tasks.zig, logica de verificare a utilizatorului și de tratare a erorilor se repetă în fiecare funcție. Ar putea fi abstractizată într-un middleware sau o funcție helper authenticatedAction.

🛠️ 2. Plan de Îmbunătățire pe Etape
Acesta este un plan structurat pentru a duce proiectul la un nivel profesional.

Etapa 1: Securitate Critică (Prioritate Zero)
Această etapă trebuie implementată imediat.

Implementează verificarea expirării sesiunii:

Modifică src/db/surreal.zig -> validateSession.

Parsează câmpul expires_at din JSON.

Compară cu std.time.milliTimestamp(). Dacă expires_at < now, returnează null și șterge sesiunea din DB.

Mută Secretele în .env:

Scoate string-ul "zig-task-manager-secret-2024" din cod.

Folosește std.process.getEnvVarOwned sau librăria ta de config pentru a-l încărca la runtime.

Folosește Parserul JSON peste tot:

Înlocuiește logica manuală din getTaskOwner și validateSession cu std.json.parseFromSlice, exact cum ai făcut în src/handlers/tasks.zig. Definește structuri mici pentru rezultatele așteptate (ex: struct { user_id: []const u8 }).

Etapa 2: Robustete și Arhitectură
Background Job pentru Rate Limiter:

În src/main.zig, înainte de listener.listen(), pornește un thread separat (std.Thread.spawn) care rulează o buclă infinită: face sleep 60 de secunde, apoi apelează rate_limiter.login_limiter.cleanup().

Middleware pentru Autentificare:

Creează un wrapper sau o funcție în handlers/auth.zig care acceptă un callback. Aceasta va verifica sesiunea și, dacă e validă, va apela logica specifică rutei. Astfel scapi de if (user_id == null) return error din fiecare handler.

Parametrizarea Query-urilor SurrealQL:

În loc de allocPrint, modifică funcția query din surreal.zig să accepte un struct de variabile. SurrealDB HTTP API permite trimiterea unui JSON cu variabile alături de query. Asta elimină nevoia de escape manual.

Etapa 3: Refactorizare și Clean Code
Gestionarea Erorilor HTTP:

Creează o funcție centralizată http.jsonError(r, code, message) care să accepte și un cod de eroare intern opțional pentru logging, ca să nu scrii JSON-ul de eroare manual de fiecare dată.

Organizarea Handler-elor:

Fișierul src/main.zig devine aglomerat cu rutele if/else. Poți crea un src/router.zig care să mapeze URL-urile la funcții folosind un StringHashMap sau o structură de tip trie pentru rute mai curate.

Etapa 4: Optimizare
Arena Allocator per Request:

Deja folosești un Arena allocator în handleRequest, ceea ce este excelent! Asigură-te doar că toate alocările din timpul request-ului folosesc req_alloc și nu allocator-ul global, pentru a garanta curățarea memoriei.

🚀 3. Funcționalități Noi Propuse
După ce codul este stabilizat, iată câteva idei pentru a extinde aplicația:

1. Categorii sau Tag-uri pentru Task-uri
Backend: Modifică schema în src/db/surreal.zig pentru a adăuga un câmp tags: array<string> la tabela tasks.

Logic: Adaugă filtrare în getTasks (ex: GET /api/tasks?tag=work).

2. Partajarea Task-urilor (Collaboration)
Idee: Permite unui utilizator să adauge alți utilizatori la un task.

Implementare:

Tabelă nouă task_shares (task_id, user_id, permission_level).

Modificarea verificării de ownership (verifyTaskOwnership) pentru a verifica și tabela de share-uri.

3. Notificări pe Email (Background Jobs)
Idee: Trimite un email când un task se apropie de termenul limită.

Implementare:

Ai nevoie de un sistem de cozi (Queue). Deoarece folosești SurrealDB, poți folosi o tabelă ca o coadă.

Un thread separat în Zig care verifică periodic task-urile cu due_date în următoarea oră și trimite emailuri (folosind src/services/email.zig).

4. Audit Log (Securitate avansată)
Idee: Ține evidența acțiunilor critice (cine a șters un task, cine s-a logat).

Implementare: O tabelă audit_logs în SurrealDB unde scrii evenimente asincron după fiecare acțiune reușită (auth, delete, etc.).

Exemplu de Cod pentru Etapa 1 (Fixarea validateSession)
Iată cum ar trebui să arate funcția validateSession în src/db/surreal.zig folosind parserul JSON și verificând expirarea:

Fragment de cod

pub fn validateSession(allocator: std.mem.Allocator, token: []const u8) !?[]u8 {
    // 1. Folosim parametri în loc de string interpolation (dacă treci la params)
    // Sau, păstrăm formatul actual dar folosim parser JSON la răspuns
    const sql = try std.fmt.allocPrint(allocator,
        \\SELECT user_id, expires_at FROM sessions WHERE token = "{s}";
    , .{token});
    defer allocator.free(sql);

    const result_json = try query(allocator, sql);
    defer allocator.free(result_json);

    // Definim structura așteptată de la SurrealDB
    const SessionResult = struct {
        user_id: []const u8,
        expires_at: []const u8, // Surreal returnează datetime ca string de obicei în JSON
    };
    
    // Folosim wrapper-ul tău de SurrealResponse sau parsezi direct
    // Aici simplific pentru exemplu
    const parsed = std.json.parseFromSlice([]models.SurrealResponse(SessionResult), allocator, result_json, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    if (parsed.value.len == 0 or parsed.value[0].result.len == 0) return null;

    const session = parsed.value[0].result[0];

    // 2. Verificăm Expirarea
    // Va trebui să parsezi string-ul de dată de la Surreal în timestamp
    // Sau, mai simplu, modifici query-ul să returneze doar dacă e valid:
    // SELECT user_id FROM sessions WHERE token = "..." AND expires_at > time::now();
    
    // Varianta Query (Mult mai eficientă):
    // Daca query-ul returnează gol, înseamnă că e expirat sau invalid.
    
    return try allocator.dupe(u8, session.user_id);
}