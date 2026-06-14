create table simulated_aircraft
(
    callsign varchar not null
        constraint simulated_aircraft_pk
        primary key,
    state    text not null
);
