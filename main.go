package main

import (
	"io"
	"log"
	"net/http"
	"os"
)

func main() {
	mux := http.NewServeMux()

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("HELLO\n"))
		file, err := os.Open("./src/main.zig")
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		defer file.Close()

		buff := make([]byte, 5*1024)
		for {
			n, err := file.Read(buff)
			if err != nil {
				if err == io.EOF {
					w.Write(buff[0:n])
					break
				}
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			w.Write(buff[0:n])
		}
	})

	s := http.Server{
		Handler: mux,
		Addr:    ":3000",
		// WriteTimeout: 100,
		// ReadTimeout:  100,
	}
	if err := s.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
