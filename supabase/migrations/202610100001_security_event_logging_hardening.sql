-- VYNET: Security event logging hardening
-- Restrict login-success event creation to the trusted server role.

CREATE OR REPLACE FUNCTION public.record_login_success_event(
  p_actor_user_id uuid,
  p_trace_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_organization_id uuid;
BEGIN
  IF p_actor_user_id IS NULL OR p_trace_id IS NULL THEN
    RAISE EXCEPTION 'invalid_security_event'
      USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.profiles AS p
    WHERE p.user_id = p_actor_user_id
  ) THEN
    RAISE EXCEPTION 'invalid_security_event'
      USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.memberships AS m
    WHERE m.user_id = p_actor_user_id
      AND m.role IN ('OWNER', 'ADMIN', 'AGENT')
  ) THEN
    RAISE EXCEPTION 'invalid_security_event'
      USING ERRCODE = '42501';
  END IF;

  SELECT
    CASE
      WHEN COUNT(DISTINCT m.organization_id) = 1
      THEN MIN(m.organization_id::text)::uuid
      ELSE NULL
    END
  INTO v_organization_id
  FROM public.memberships AS m
  WHERE m.user_id = p_actor_user_id
    AND m.role IN ('OWNER', 'ADMIN', 'AGENT');

  INSERT INTO public.security_events (
    organization_id,
    actor_user_id,
    event_type,
    result,
    trace_id
  )
  VALUES (
    v_organization_id,
    p_actor_user_id,
    'LOGIN_SUCCESS',
    'SUCCESS',
    p_trace_id
  );
END;
$function$;

-- Disable the legacy client-callable entry points.
REVOKE ALL ON FUNCTION
  public.record_security_event(text, uuid)
FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION
  private.record_security_event_impl(text, uuid)
FROM PUBLIC, anon, authenticated, service_role;

-- Only the trusted server role may create login-success events.
REVOKE ALL ON FUNCTION
  public.record_login_success_event(uuid, uuid)
FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION
  public.record_login_success_event(uuid, uuid)
TO service_role;
