package db

import "database/sql"

type PostgresSimAircraftRepository struct {
	db *sql.DB
}

func (r *PostgresSimAircraftRepository) Save(rec *SimAircraftRecord) (err error) {
	_, err = r.db.Exec(`
		INSERT INTO simulated_aircraft (callsign, state) VALUES ($1, $2)
		ON CONFLICT(callsign) DO UPDATE SET state = excluded.state;`,
		rec.Callsign, rec.State,
	)
	return
}

func (r *PostgresSimAircraftRepository) Delete(callsign string) (err error) {
	_, err = r.db.Exec(`DELETE FROM simulated_aircraft WHERE callsign = $1;`, callsign)
	return
}

func (r *PostgresSimAircraftRepository) LoadAll() (records []*SimAircraftRecord, err error) {
	rows, err := r.db.Query(`SELECT callsign, state FROM simulated_aircraft;`)
	if err != nil {
		return
	}
	defer rows.Close()

	for rows.Next() {
		rec := &SimAircraftRecord{}
		if err = rows.Scan(&rec.Callsign, &rec.State); err != nil {
			return
		}
		records = append(records, rec)
	}
	err = rows.Err()
	return
}
