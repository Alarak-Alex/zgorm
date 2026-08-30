package main

import (
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"sort"
	"strconv"
	"sync"
	"syscall"
	"time"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

type BenchUser struct {
	ID        int64 `gorm:"primaryKey"`
	CreatedAt time.Time
	UpdatedAt time.Time
	DeletedAt gorm.DeletedAt `gorm:"index"`
	Name      string
	Score     int64
	Posts     []BenchPost `gorm:"foreignKey:UserID"`
}

func (BenchUser) TableName() string { return "zorm_bench_users" }

type BenchPost struct {
	ID     int64 `gorm:"primaryKey"`
	UserID int64 `gorm:"index"`
	Title  string
}

func (BenchPost) TableName() string { return "zorm_bench_posts" }

type result struct {
	ORM              string  `json:"orm"`
	Mode             string  `json:"mode"`
	Case             string  `json:"case"`
	Warmup           int     `json:"warmup"`
	Iterations       int     `json:"iterations"`
	OpsPerSecond     float64 `json:"ops_per_second"`
	P50NS            int64   `json:"p50_ns"`
	P95NS            int64   `json:"p95_ns"`
	P99NS            int64   `json:"p99_ns"`
	P999NS           int64   `json:"p999_ns"`
	AllocationsPerOp float64 `json:"allocations_per_op"`
	BytesPerOp       float64 `json:"bytes_per_op"`
	CPUUS            int64   `json:"cpu_us"`
	PeakRSSBytes     int64   `json:"peak_rss_bytes"`
	PoolWaitCount    int64   `json:"pool_wait_count"`
	PoolWaitNS       int64   `json:"pool_wait_ns"`
}

func setup(db *gorm.DB) error {
	if err := db.Exec("DROP TABLE IF EXISTS zorm_bench_posts CASCADE").Error; err != nil {
		return err
	}
	if err := db.Exec("DROP TABLE IF EXISTS zorm_bench_users CASCADE").Error; err != nil {
		return err
	}
	if err := db.AutoMigrate(&BenchUser{}, &BenchPost{}); err != nil {
		return err
	}
	users := make([]BenchUser, 1000)
	posts := make([]BenchPost, 1000)
	for i := range users {
		users[i] = BenchUser{Name: fmt.Sprintf("user-%d", i), Score: int64(i)}
	}
	if err := db.CreateInBatches(&users, 1000).Error; err != nil {
		return err
	}
	for i := range posts {
		posts[i] = BenchPost{UserID: int64(i + 1), Title: fmt.Sprintf("post-%d", i)}
	}
	return db.CreateInBatches(&posts, 1000).Error
}

func memory() (uint64, uint64) {
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	return stats.Mallocs, stats.TotalAlloc
}

func resources() (int64, int64) {
	var usage syscall.Rusage
	if syscall.Getrusage(syscall.RUSAGE_SELF, &usage) != nil {
		return 0, 0
	}
	cpu := usage.Utime.Sec*1_000_000 + int64(usage.Utime.Usec) + usage.Stime.Sec*1_000_000 + int64(usage.Stime.Usec)
	rss := usage.Maxrss
	if runtime.GOOS != "darwin" {
		rss *= 1024
	}
	return cpu, rss
}

func percentile(values []int64, numerator, denominator int) int64 {
	if len(values) == 0 {
		return 0
	}
	index := (len(values)*numerator+denominator-1)/denominator - 1
	if index >= len(values) {
		index = len(values) - 1
	}
	return values[index]
}

func runCase(mode, name string, db *gorm.DB, warmup, iterations int, operation func(int) error) error {
	for i := range warmup {
		if err := operation(i + 1_000_000); err != nil {
			return fmt.Errorf("%s warmup: %w", name, err)
		}
	}
	latencies := make([]int64, iterations)
	mallocsBefore, bytesBefore := memory()
	cpuBefore, _ := resources()
	sqlDB, err := db.DB()
	if err != nil {
		return err
	}
	poolBefore := sqlDB.Stats()
	started := time.Now()
	for i := range latencies {
		one := time.Now()
		if err := operation(i); err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
		latencies[i] = time.Since(one).Nanoseconds()
	}
	elapsed := time.Since(started)
	poolAfter := sqlDB.Stats()
	cpuAfter, rss := resources()
	mallocsAfter, bytesAfter := memory()
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	return json.NewEncoder(os.Stdout).Encode(result{
		ORM: "gorm", Mode: mode, Case: name, Warmup: warmup, Iterations: iterations,
		OpsPerSecond: float64(iterations) / elapsed.Seconds(),
		P50NS:        percentile(latencies, 50, 100), P95NS: percentile(latencies, 95, 100),
		P99NS: percentile(latencies, 99, 100), P999NS: percentile(latencies, 999, 1000),
		AllocationsPerOp: float64(mallocsAfter-mallocsBefore) / float64(iterations),
		BytesPerOp:       float64(bytesAfter-bytesBefore) / float64(iterations),
		CPUUS:            cpuAfter - cpuBefore, PeakRSSBytes: rss,
		PoolWaitCount: poolAfter.WaitCount - poolBefore.WaitCount,
		PoolWaitNS:    (poolAfter.WaitDuration - poolBefore.WaitDuration).Nanoseconds(),
	})
}

func runConcurrency(mode string, db *gorm.DB, concurrency, operations int) error {
	latencies := make([]int64, concurrency*operations)
	mallocsBefore, bytesBefore := memory()
	cpuBefore, _ := resources()
	sqlDB, _ := db.DB()
	poolBefore := sqlDB.Stats()
	started := time.Now()
	var wg sync.WaitGroup
	errs := make(chan error, concurrency)
	for worker := range concurrency {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for i := range operations {
				one := time.Now()
				var user BenchUser
				err := db.First(&user, int64((worker*operations+i)%1000+1)).Error
				latencies[worker*operations+i] = time.Since(one).Nanoseconds()
				if err != nil {
					errs <- err
					return
				}
			}
		}(worker)
	}
	wg.Wait()
	close(errs)
	if err := <-errs; err != nil {
		return err
	}
	elapsed := time.Since(started)
	poolAfter := sqlDB.Stats()
	cpuAfter, rss := resources()
	mallocsAfter, bytesAfter := memory()
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	total := len(latencies)
	return json.NewEncoder(os.Stdout).Encode(result{
		ORM: "gorm", Mode: mode, Case: fmt.Sprintf("concurrency-%d", concurrency), Iterations: total,
		OpsPerSecond: float64(total) / elapsed.Seconds(),
		P50NS:        percentile(latencies, 50, 100), P95NS: percentile(latencies, 95, 100),
		P99NS: percentile(latencies, 99, 100), P999NS: percentile(latencies, 999, 1000),
		AllocationsPerOp: float64(mallocsAfter-mallocsBefore) / float64(total),
		BytesPerOp:       float64(bytesAfter-bytesBefore) / float64(total),
		CPUUS:            cpuAfter - cpuBefore, PeakRSSBytes: rss,
		PoolWaitCount: poolAfter.WaitCount - poolBefore.WaitCount,
		PoolWaitNS:    (poolAfter.WaitDuration - poolBefore.WaitDuration).Nanoseconds(),
	})
}

func run(mode, dsn string, warmup, iterations, poolSize int) error {
	config := &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)}
	if mode == "tuned" {
		config.SkipDefaultTransaction = true
		config.PrepareStmt = true
	}
	db, err := gorm.Open(postgres.Open(dsn), config)
	if err != nil {
		return err
	}
	sqlDB, err := db.DB()
	if err != nil {
		return err
	}
	defer sqlDB.Close()
	sqlDB.SetMaxOpenConns(poolSize)
	sqlDB.SetMaxIdleConns(poolSize)
	if err := setup(db); err != nil {
		return err
	}

	if err := runCase(mode, "primary-key", db, warmup, iterations, func(i int) error {
		var user BenchUser
		return db.First(&user, int64(i%1000+1)).Error
	}); err != nil {
		return err
	}
	for _, count := range []int{10, 100, 1000} {
		if err := runCase(mode, fmt.Sprintf("query-%d", count), db, warmup, iterations, func(_ int) error {
			var users []BenchUser
			return db.Limit(count).Find(&users).Error
		}); err != nil {
			return err
		}
	}
	if err := runCase(mode, "insert", db, warmup, iterations, func(i int) error {
		return db.Create(&BenchUser{Name: fmt.Sprintf("insert-%d", i)}).Error
	}); err != nil {
		return err
	}
	if err := runCase(mode, "update", db, warmup, iterations, func(i int) error {
		return db.Model(&BenchUser{}).Where("id = ?", i%1000+1).Update("score", gorm.Expr("score + 1")).Error
	}); err != nil {
		return err
	}
	if err := runCase(mode, "delete", db, warmup, iterations, func(i int) error {
		user := BenchUser{Name: fmt.Sprintf("delete-%d", i)}
		if err := db.Create(&user).Error; err != nil {
			return err
		}
		return db.Unscoped().Delete(&user).Error
	}); err != nil {
		return err
	}
	if err := runCase(mode, "soft-delete", db, warmup, iterations, func(i int) error {
		user := BenchUser{Name: fmt.Sprintf("soft-%d", i)}
		if err := db.Create(&user).Error; err != nil {
			return err
		}
		return db.Delete(&user).Error
	}); err != nil {
		return err
	}
	if err := runCase(mode, "batch-insert-100", db, max(warmup/10, 1), max(iterations/10, 1), func(i int) error {
		users := make([]BenchUser, 100)
		for j := range users {
			users[j].Name = fmt.Sprintf("batch-%d-%d", i, j)
		}
		return db.CreateInBatches(&users, 100).Error
	}); err != nil {
		return err
	}
	if err := runCase(mode, "transaction", db, warmup, iterations, func(_ int) error {
		return db.Transaction(func(tx *gorm.DB) error { return tx.Exec("SELECT 1").Error })
	}); err != nil {
		return err
	}
	if err := runCase(mode, "preload", db, warmup, iterations, func(_ int) error {
		var users []BenchUser
		return db.Preload("Posts").Limit(10).Find(&users).Error
	}); err != nil {
		return err
	}
	for i := range warmup {
		var user BenchUser
		if err := db.First(&user, int64(i%1000+1)).Error; err != nil {
			return err
		}
	}
	for _, concurrency := range []int{1, 16, 128, 512} {
		if err := runConcurrency(mode, db, concurrency, iterations); err != nil {
			return err
		}
	}
	return nil
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func main() {
	dsn := os.Getenv("ZORM_DSN")
	if dsn == "" {
		dsn = "postgres://zorm:zorm@127.0.0.1:5433/zorm?sslmode=disable"
	}
	iterations := 100
	if value := os.Getenv("ZORM_BENCH_ITERS"); value != "" {
		var err error
		iterations, err = strconv.Atoi(value)
		if err != nil {
			panic(err)
		}
	}
	warmup := 20
	if value := os.Getenv("ZORM_BENCH_WARMUP"); value != "" {
		var err error
		warmup, err = strconv.Atoi(value)
		if err != nil {
			panic(err)
		}
	}
	poolSize := 32
	if value := os.Getenv("ZORM_BENCH_POOL"); value != "" {
		var err error
		poolSize, err = strconv.Atoi(value)
		if err != nil {
			panic(err)
		}
	}
	mode := os.Getenv("GORM_BENCH_MODE")
	if mode == "" {
		mode = "default"
	}
	if err := run(mode, dsn, warmup, iterations, poolSize); err != nil {
		panic(err)
	}
}
