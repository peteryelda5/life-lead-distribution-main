-- Pure phone normalization helper used by lead indexes/triggers during invoker updates.
-- Reads only its arguments; no table access or elevated privileges.
grant execute on function private.dialer_callback_phone(text,jsonb,jsonb) to authenticated;

