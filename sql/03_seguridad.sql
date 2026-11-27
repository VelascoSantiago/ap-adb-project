-- ============================================================================
-- 03_seguridad.sql  ·  BLOQUE 2: Seguridad multinivel
-- Proyecto BDA - Equipo 7 · PostgreSQL 16 (Docker)
--
-- Contenido:
--   1. Limpieza (re-ejecutable) y cierre del acceso por defecto
--   2. Roles de grupo (RBAC) y usuarios
--   3. DAC  : GRANT / REVOKE / WITH GRANT OPTION / permisos por columna
--   4. RBAC : privilegios solo a roles de grupo; los usuarios heredan
--   5. MAC  : aproximación con Row Level Security + niveles de acceso
--   6. Auditoría con pgaudit (sesión + objeto)
--   7. Pruebas de acceso, modificación y auditoría (conectado como cada usuario)
--
-- Equivalencias Oracle -> PostgreSQL:
--   CREATE USER / CREATE ROLE        -> CREATE ROLE ... LOGIN / NOLOGIN
--   GRANT priv ... WITH GRANT OPTION -> igual
--   Oracle Label Security (MAC)      -> NO existe; se aproxima con RLS (CREATE POLICY)
--   AUDIT / Unified Auditing         -> extensión pgaudit + trigger de bitácora (02)
--
-- Requiere haber ejecutado 02_esquema.sql (los GRANT se pierden si se recrea el esquema).
-- Se ejecuta como superusuario (postgres). Las pruebas cambian de usuario con \c.
-- ============================================================================

\set ON_ERROR_STOP on
SELECT current_database() AS db \gset

\echo '== 1. LIMPIEZA Y CIERRE DEL ACCESO POR DEFECTO =========================='

-- Los roles son del clúster (no de un esquema), así que se borran explícitamente.
-- DROP OWNED BY revoca todos los privilegios que el rol tenga en esta BD.
DO $$
DECLARE r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['admin_santiago','auditor_armando','analista_laura','analista_jr',
                             'usuario_sin_rol','rol_admin','rol_analista','rol_auditor','auditoria_obj']
    LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('DROP OWNED BY %I', r);
            EXECUTE format('DROP ROLE %I', r);
        END IF;
    END LOOP;
END $$;

DROP SCHEMA IF EXISTS seg CASCADE;   -- arrastra las políticas RLS que dependen de seg.fn_nivel_acceso()

-- Principio de mínimo privilegio: por defecto PUBLIC no puede conectarse ni ver nada.
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
REVOKE ALL ON SCHEMA public, rh, audit FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA rh, audit FROM PUBLIC;

\echo '== 2. ROLES DE GRUPO (RBAC) Y USUARIOS =================================='

-- Roles de grupo: NOLOGIN. Nadie inicia sesión con ellos; solo agrupan privilegios.
CREATE ROLE rol_admin    NOLOGIN;   -- administra los datos de RH (no ve la bitácora)
CREATE ROLE rol_analista NOLOGIN;   -- consulta y analiza (lectura restringida)
CREATE ROLE rol_auditor  NOLOGIN;   -- solo lectura de todo + bitácora (separación de funciones)

-- Usuarios reales (uno por integrante) y ficticios para la demo.
-- Contraseñas de demostración: en producción vendrían de un gestor de secretos.
CREATE ROLE admin_santiago  LOGIN PASSWORD 'Demo#Admin26'   IN ROLE rol_admin;
CREATE ROLE auditor_armando LOGIN PASSWORD 'Demo#Audit26'   IN ROLE rol_auditor;
CREATE ROLE analista_laura  LOGIN PASSWORD 'Demo#Analis26'  IN ROLE rol_analista;
CREATE ROLE analista_jr     LOGIN PASSWORD 'Demo#Junior26'  IN ROLE rol_analista;  -- analista de nivel bajo
CREATE ROLE usuario_sin_rol LOGIN PASSWORD 'Demo#Nada26';                          -- sin privilegios

GRANT CONNECT ON DATABASE :"db" TO rol_admin, rol_analista, rol_auditor;
GRANT CONNECT ON DATABASE :"db" TO usuario_sin_rol;   -- puede entrar, pero no ve nada
GRANT USAGE   ON SCHEMA rh TO usuario_sin_rol;        -- ve el esquema, pero ninguna tabla (hasta que se le delegue)

GRANT USAGE ON SCHEMA rh    TO rol_admin, rol_analista, rol_auditor;
GRANT USAGE ON SCHEMA audit TO rol_auditor;

\echo '== 3-4. DAC + RBAC: PRIVILEGIOS SOBRE OBJETOS ==========================='

-- DAC (Discrecional): el dueño decide quién accede a sus objetos y puede delegar
--   con WITH GRANT OPTION. RBAC: los privilegios se dan SOLO a roles de grupo.
-- Se otorga sobre la tabla padre; las particiones NO se exponen (una consulta
-- directa a una partición se saltaría las políticas RLS de la tabla padre).

-- rol_admin: CRUD completo. Sin TRUNCATE (ignora RLS; es tarea del DBA/mantenimiento).
GRANT SELECT, INSERT, UPDATE, DELETE
   ON rh.departamento, rh.rol_laboral, rh.empleado, rh.asistencia
   TO rol_admin WITH GRANT OPTION;               -- DAC: puede delegar estos permisos
GRANT SELECT ON rh.vw_resumen_departamento, rh.vw_empleado_publico TO rol_admin;

-- rol_analista: lectura. En empleado, permiso POR COLUMNA: no puede ver el email.
GRANT SELECT ON rh.departamento, rh.rol_laboral, rh.asistencia TO rol_analista;
GRANT SELECT (empleado_id, nombre, apellido, depto_id, rol_id, salario,
              fecha_ingreso, activo, nivel_confidencialidad)
   ON rh.empleado TO rol_analista;
GRANT SELECT ON rh.vw_resumen_departamento, rh.vw_empleado_publico TO rol_analista;

-- rol_auditor: solo lectura de todo + la bitácora. Nunca escribe.
GRANT SELECT ON rh.departamento, rh.rol_laboral, rh.empleado, rh.asistencia,
                rh.vw_resumen_departamento, rh.vw_empleado_publico TO rol_auditor;
GRANT SELECT ON audit.bitacora TO rol_auditor;

-- Los identificadores GENERATED ALWAYS AS IDENTITY no requieren permiso sobre la secuencia.

\echo '== 5. MAC (aproximación con ROW LEVEL SECURITY) ========================='

-- Oracle Label Security no existe en PostgreSQL. Se aproxima el modelo de
-- Bell-LaPadula ("no read up"): cada fila lleva un nivel (nivel_confidencialidad:
-- 1 público, 2 interno, 3 confidencial) y cada sujeto una habilitación (clearance).
-- Un sujeto solo ve/modifica filas con nivel <= su habilitación.
-- A diferencia de DAC, el dueño de la fila NO puede cambiar esta regla a su gusto.

CREATE SCHEMA seg;
COMMENT ON SCHEMA seg IS 'Habilitaciones (clearance) del modelo MAC aproximado con RLS';

-- Habilitación por rol o por usuario. Una fila de usuario tiene prioridad sobre las de sus roles.
CREATE TABLE seg.nivel_acceso (
    sujeto  NAME     PRIMARY KEY,                       -- nombre de rol o de usuario
    nivel   SMALLINT NOT NULL CHECK (nivel BETWEEN 0 AND 3)
);
INSERT INTO seg.nivel_acceso (sujeto, nivel) VALUES
    ('rol_analista',   2),     -- ve público e interno
    ('rol_auditor',    3),     -- ve todo
    ('rol_admin',      3),     -- ve y modifica todo
    ('analista_jr',    1);     -- excepción: un analista junior solo ve nivel público

-- Devuelve la habilitación efectiva de current_user. NO es SECURITY DEFINER a
-- propósito: así current_user respeta SET ROLE (útil en la demo).
CREATE FUNCTION seg.fn_nivel_acceso() RETURNS SMALLINT
LANGUAGE sql STABLE
SET search_path = seg, pg_catalog
AS $$
    SELECT COALESCE(
        (SELECT n.nivel
           FROM seg.nivel_acceso n
          WHERE pg_has_role(current_user, n.sujeto, 'member')   -- el usuario o alguno de sus roles
          ORDER BY (n.sujeto = current_user::name) DESC,        -- primero la regla específica del usuario
                   n.nivel DESC
          LIMIT 1), 0)::smallint;
$$;

GRANT USAGE ON SCHEMA seg TO rol_admin, rol_analista, rol_auditor;
GRANT SELECT ON seg.nivel_acceso TO rol_admin, rol_analista, rol_auditor;
GRANT EXECUTE ON FUNCTION seg.fn_nivel_acceso() TO rol_admin, rol_analista, rol_auditor;

ALTER TABLE rh.empleado ENABLE ROW LEVEL SECURITY;
-- (El superusuario y el dueño siempre pasan por encima de RLS; los demás roles no.)

DROP POLICY IF EXISTS mac_lectura   ON rh.empleado;
DROP POLICY IF EXISTS mac_escritura ON rh.empleado;

-- Lectura: ningún rol ve filas por encima de su habilitación.
-- (SELECT fn()) fuerza a evaluar la función una sola vez por consulta (InitPlan), no por fila.
CREATE POLICY mac_lectura ON rh.empleado FOR SELECT
    TO rol_admin, rol_analista, rol_auditor
    USING (nivel_confidencialidad <= (SELECT seg.fn_nivel_acceso()));

-- Escritura (solo admin): USING filtra qué filas puede tocar y WITH CHECK impide
-- insertar/mover filas a un nivel superior al suyo.
CREATE POLICY mac_escritura ON rh.empleado FOR ALL
    TO rol_admin
    USING      (nivel_confidencialidad <= (SELECT seg.fn_nivel_acceso()))
    WITH CHECK (nivel_confidencialidad <= (SELECT seg.fn_nivel_acceso()));

-- El resumen por departamento pasa a ejecutarse con los permisos (y RLS) de quien consulta:
-- así la nómina agregada que ve un analista no incluye a los puestos confidenciales.
ALTER VIEW rh.vw_resumen_departamento SET (security_invoker = true);
-- vw_empleado_publico queda como vista "definer": expone solo columnas no sensibles a propósito.

\echo '== 6. AUDITORÍA CON PGAUDIT ============================================='

-- Auditoría de sesión: registra DDL, escrituras (INSERT/UPDATE/DELETE) y cambios de roles/permisos.
ALTER DATABASE :"db" SET pgaudit.log = 'ddl, write, role';
ALTER DATABASE :"db" SET pgaudit.log_parameter = on;

-- Auditoría de objeto: se registra TODO acceso a las columnas para las que
-- 'auditoria_obj' tenga privilegio. Aquí: cualquier lectura de salario/email.
CREATE ROLE auditoria_obj NOLOGIN;
GRANT SELECT (salario, email) ON rh.empleado TO auditoria_obj;
ALTER DATABASE :"db" SET pgaudit.role = 'auditoria_obj';

-- Incluye usuario y BD en cada línea del log (pgaudit no los imprime por sí mismo).
ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d ';
SELECT pg_reload_conf();

\echo '-- 6.1 Estado de la configuración (las conexiones NUEVAS ya la usan)'
SELECT name, setting FROM pg_settings WHERE name IN ('shared_preload_libraries','log_line_prefix');
SELECT setconfig FROM pg_db_role_setting WHERE setdatabase = (SELECT oid FROM pg_database WHERE datname = :'db');

\echo '== 7. PRUEBAS ==========================================================='
\echo '(Las líneas "ERROR: permission denied..." son el RESULTADO ESPERADO de las pruebas negativas.)'
\set ON_ERROR_STOP off

\echo ''
\echo '-- 7.1 Resumen de roles y membresías (RBAC)'
SELECT r.rolname AS rol, r.rolcanlogin AS login,
       COALESCE(string_agg(g.rolname, ', ' ORDER BY g.rolname), '-') AS miembro_de
FROM pg_roles r
LEFT JOIN pg_auth_members m ON m.member = r.oid
LEFT JOIN pg_roles g        ON g.oid = m.roleid
WHERE r.rolname ~ '^(rol_|admin_|auditor_|analista_|usuario_|auditoria_)'
GROUP BY r.rolname, r.rolcanlogin ORDER BY 1;

\echo ''
\echo '== 7.2 ANALISTA (analista_laura, rol_analista, nivel 2) ================='
\c :db analista_laura
SELECT current_user AS usuario, seg.fn_nivel_acceso() AS nivel_acceso;
\echo '-- MAC: ve solo filas de nivel <= 2 (los Director/Gerente de nivel 3 no aparecen)'
SELECT nivel_confidencialidad AS nivel, COUNT(*) AS empleados FROM rh.empleado GROUP BY 1 ORDER BY 1;
\echo '-- Lectura permitida (columnas permitidas):'
SELECT empleado_id, nombre, apellido, salario FROM rh.empleado ORDER BY salario DESC LIMIT 3;
\echo '-- DENEGADO (DAC por columna): leer el email'
SELECT email FROM rh.empleado LIMIT 1;
\echo '-- DENEGADO: modificar'
UPDATE rh.empleado SET salario = salario + 1;
\echo '-- DENEGADO: insertar'
INSERT INTO rh.departamento (nombre) VALUES ('Intruso');
\echo '-- DENEGADO: leer la bitácora de auditoría'
SELECT COUNT(*) FROM audit.bitacora;
\echo '-- DENEGADO: leer una partición directamente (saltaría RLS)'
SELECT COUNT(*) FROM rh.empleado_2024_2027;
\echo '-- DENEGADO: delegar permisos (no tiene GRANT OPTION)'
GRANT SELECT ON rh.departamento TO usuario_sin_rol;
\echo '-- Vista pública (definer): ve a todos, pero sin salario ni email'
SELECT COUNT(*) AS empleados_visibles FROM rh.vw_empleado_publico;
\echo '-- Resumen por departamento (security_invoker): la nómina solo suma lo que ella puede ver'
SELECT departamento, empleados, nomina_total FROM rh.vw_resumen_departamento ORDER BY 1;

\echo ''
\echo '== 7.3 ANALISTA JUNIOR (analista_jr, mismo rol, pero nivel 1) ==========='
\c :db analista_jr
SELECT current_user AS usuario, seg.fn_nivel_acceso() AS nivel_acceso;
SELECT nivel_confidencialidad AS nivel, COUNT(*) AS empleados FROM rh.empleado GROUP BY 1 ORDER BY 1;
\echo '-- Mismo rol, distinta habilitación: MAC por usuario sobreescribe lo heredado del rol'

\echo ''
\echo '== 7.4 ADMINISTRADOR (admin_santiago, rol_admin, nivel 3) ================'
\c :db admin_santiago
SELECT current_user AS usuario, seg.fn_nivel_acceso() AS nivel_acceso;
SELECT nivel_confidencialidad AS nivel, COUNT(*) AS empleados FROM rh.empleado GROUP BY 1 ORDER BY 1;
\echo '-- Modificación permitida (dentro del rango salarial del rol; la audita trigger + pgaudit)'
UPDATE rh.empleado SET salario = 36500 WHERE email = 'elena.flores@empresa.mx';
\echo '-- Rechazado por el trigger de negocio (Auxiliar con salario de Director)'
UPDATE rh.empleado SET salario = 90000 WHERE email = 'sofia.martinez@empresa.mx';
\echo '-- DENEGADO: el admin NO puede leer la bitácora (separación de funciones)'
SELECT COUNT(*) FROM audit.bitacora;
\echo '-- DENEGADO: TRUNCATE (ignoraría RLS; reservado al DBA)'
TRUNCATE rh.empleado;
\echo '-- DAC con GRANT OPTION: el admin delega lectura de un catálogo a otro usuario...'
GRANT SELECT ON rh.departamento TO usuario_sin_rol;
\c :db usuario_sin_rol
SELECT nombre FROM rh.departamento ORDER BY 1 LIMIT 2;
\echo '-- ...y la revoca (REVOKE)'
\c :db admin_santiago
REVOKE SELECT ON rh.departamento FROM usuario_sin_rol;
\c :db usuario_sin_rol
SELECT nombre FROM rh.departamento LIMIT 1;

\echo ''
\echo '== 7.5 SIN ROL (usuario_sin_rol): todo denegado por defecto ============='
SELECT * FROM rh.empleado;
SELECT * FROM audit.bitacora;

\echo ''
\echo '== 7.6 AUDITOR (auditor_armando, rol_auditor, nivel 3) =================='
\c :db auditor_armando
SELECT current_user AS usuario, seg.fn_nivel_acceso() AS nivel_acceso;
\echo '-- Ve todo, incluido el email (lectura auditada por pgaudit)'
SELECT nivel_confidencialidad AS nivel, COUNT(*) AS empleados FROM rh.empleado GROUP BY 1 ORDER BY 1;
SELECT nombre, apellido, email, salario FROM rh.empleado WHERE nivel_confidencialidad = 3 ORDER BY salario DESC LIMIT 2;
\echo '-- DENEGADO: el auditor no modifica datos'
UPDATE rh.empleado SET salario = 1 WHERE email = 'roberto.salinas@empresa.mx';
\echo '-- DENEGADO: ni borra la bitácora'
DELETE FROM audit.bitacora;
\echo '-- Bitácora (trigger): quién cambió qué, con valores old/new'
SELECT bitacora_id, usuario, operacion, tabla, registro_id,
       datos_old ->> 'salario' AS salario_old, datos_new ->> 'salario' AS salario_new
FROM audit.bitacora ORDER BY bitacora_id DESC LIMIT 5;

\echo ''
\echo '== 7.7 SET ROLE (alternativa para la demo, desde el superusuario) ======='
\c :db postgres
SET ROLE analista_laura;
SELECT current_user, session_user, seg.fn_nivel_acceso() AS nivel_acceso,
       (SELECT COUNT(*) FROM rh.empleado) AS empleados_visibles;
RESET ROLE;
SELECT current_user, (SELECT COUNT(*) FROM rh.empleado) AS empleados_visibles_superusuario;

\echo ''
\echo '== 7.8 PRIVILEGIOS FINALES (matriz) ====================================='
SELECT grantee, table_name, string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privilegios
FROM information_schema.role_table_grants
WHERE table_schema IN ('rh','audit')
  AND grantee IN ('rol_admin','rol_analista','rol_auditor')
  AND table_name !~ '_(p[0-9]|20[0-9]{2}.*|default|hasta_2019)$'
GROUP BY grantee, table_name ORDER BY table_name, grantee;

\echo ''
\echo '-- 7.9 Políticas RLS vigentes'
SELECT tablename, policyname, cmd, roles FROM pg_policies WHERE schemaname = 'rh' ORDER BY 1, 2;

\echo ''
\echo 'Registro de pgaudit: make audit-log  (guarda evidencias/03_pgaudit_log.txt)'
