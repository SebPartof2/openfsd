package db

// SimAircraftRecord is the persisted state of a single simulated aircraft.
// State holds a JSON-encoded snapshot owned by the fsd package.
type SimAircraftRecord struct {
	Callsign string
	State    string
}

type SimAircraftRepository interface {
	// Save upserts a simulated aircraft record by callsign.
	Save(rec *SimAircraftRecord) (err error)

	// Delete removes a simulated aircraft record by callsign.
	Delete(callsign string) (err error)

	// LoadAll returns every persisted simulated aircraft record.
	LoadAll() (records []*SimAircraftRecord, err error)
}
