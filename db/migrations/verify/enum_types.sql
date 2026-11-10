-- Verify pitch:enum_types on pg

DO $$
BEGIN
    ASSERT enum_range(NULL::competition_type)::text = '{league,cup,international}',
        'competition_type has unexpected labels';
    ASSERT enum_range(NULL::player_position)::text = '{goalkeeper,defender,midfielder,forward}',
        'player_position has unexpected labels';
    ASSERT enum_range(NULL::transfer_type)::text = '{permanent,loan,free,youth_promotion}',
        'transfer_type has unexpected labels';
    ASSERT enum_range(NULL::match_status)::text = '{scheduled,in_play,finished,postponed,cancelled}',
        'match_status has unexpected labels';
    ASSERT enum_range(NULL::match_event_type)::text = '{goal,own_goal,penalty_scored,penalty_missed,yellow_card,second_yellow_card,red_card,substitution_in,substitution_out}',
        'match_event_type has unexpected labels';
END
$$;
