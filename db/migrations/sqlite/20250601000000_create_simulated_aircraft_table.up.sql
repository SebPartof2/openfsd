create table simulated_aircraft
(
    callsign text not null
        constraint simulated_aircraft_pk
        primary key,
    state    text not null
);
