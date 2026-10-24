-- Release step: apply only after 20261024-required-onboarding assets and API
-- checks are serving in production. Do not roll back the portal alone afterward.
update private.portal_onboarding_gate set enabled=true where singleton;
