create policy "profiles_select_related_invites"
  on public.profiles
  for select
  to authenticated
  using (
    auth.uid() = id
    or exists (
      select 1
      from public.partnership_invitations invitations
      where public.profiles.id in (invitations.inviter_id, invitations.invitee_id)
        and auth.uid() in (invitations.inviter_id, invitations.invitee_id)
    )
  );