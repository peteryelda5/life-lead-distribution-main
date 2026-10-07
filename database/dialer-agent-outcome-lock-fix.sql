-- Agents read their assigned leads but cannot directly update lead rows.
-- FOR UPDATE in the outcome RPC therefore needs definer privileges.
-- Existing verified_portal_session, explicit auth.uid ownership, allowed outcomes,
-- optimistic concurrency checks and narrow status/notes RPCs remain enforced.
alter function public.save_dialer_lead_outcome(uuid,text,text,text,text) security definer;
