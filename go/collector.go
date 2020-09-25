package main

import (
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"mime/multipart"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type Collector struct {
	Config
	logger        *log.Logger
	workerGroup   *sync.WaitGroup
	filesToUpload chan infoWithPath
	Statistics    *CollectionStatistics
}

type CollectionStatistics struct {
	uploadedFiles int64
	skippedFiles  int64
	uploadErrors  int64
	fileErrors    int64
}

func NewCollector(config Config, logger *log.Logger) *Collector {
	return &Collector{
		Config: config,
		logger: logger,
	}
}

// debugf calls logger.Printf if and only if debugging is enabled.
// Arguments are handled in the manner of fmt.Printf.

func (c *Collector) debugf(format string, params ...interface{}) {
	if c.Debug {
		c.logger.Printf(format, params...)
	}
}

func (c *Collector) StartWorkers() {
	c.debugf("Starting %d threads for uploads", c.Threads)
	c.workerGroup = &sync.WaitGroup{}
	c.filesToUpload = make(chan infoWithPath)
	c.Statistics = &CollectionStatistics{}
	for i := 0; i < c.Threads; i++ {
		c.workerGroup.Add(1)
		go func() {
			for info := range c.filesToUpload {
				shouldRedo := true
				for shouldRedo {
					shouldRedo = c.uploadToThunderstorm(info)
				}
			}
			c.workerGroup.Done()
		}()
	}
}

func (c *Collector) CheckThunderstormUp() error {
	c.debugf("Checking whether Thunderstorm at %s answers", c.Server)
	response, err := http.Get(fmt.Sprintf("%s/api/status", c.Server))
	if err != nil {
		if urlError, isUrlError := err.(*url.Error); isUrlError {
			if opError, isOpError := urlError.Err.(*net.OpError); isOpError {
				if opError.Op == "dial" {
					return fmt.Errorf("%w - did you enter host and port correctly", opError)
				}
			}
			return urlError.Err
		}
		return err
	}
	body, _ := ioutil.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != 200 {
		return fmt.Errorf("server didn't answer with an OK response code on status page, received code %d: %s", response.StatusCode, body)
	}
	c.debugf("Read status page from %s/api/status", c.Server)
	return nil
}

func (c *Collector) Collect(root string) {
	c.logger.Printf("Walking through %s to find files to upload", root)
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if !info.Mode().IsDir() {
			c.filesToUpload <- infoWithPath{info, path, 0}
		}
		return nil
	})
	if err != nil {
		c.logger.Printf("Could not walk path %s: %v\n", root, err)
	}
	c.logger.Printf("Finished walking through %s", root)
}

func (c *Collector) Stop() {
	c.debugf("Waiting for pending uploads to finish...")
	close(c.filesToUpload)
	c.workerGroup.Wait()
	c.logger.Printf("Uploaded files: %d files", c.Statistics.uploadedFiles)
	c.logger.Printf("Failed to read files: %d files", c.Statistics.fileErrors)
	c.logger.Printf("Skipped files: %d files", c.Statistics.skippedFiles)
	c.logger.Printf("Failed uploads: %d files", c.Statistics.uploadErrors)
}

type infoWithPath struct {
	os.FileInfo
	path    string
	retries int
}

var MB int64 = 1024 * 1024

func (c *Collector) uploadToThunderstorm(info infoWithPath) (redo bool) {
	if !info.Mode().IsRegular() {
		atomic.AddInt64(&c.Statistics.skippedFiles, 1)
		c.debugf("Skipping irregular file %s", info.path)
		return
	}
	if c.MaxAgeInDays > 0 {
		isTooOld := true
		thresholdTime := time.Now().Add(-1 * time.Duration(c.MaxAgeInDays) * 24 * time.Hour)
		for _, time := range getTimes(info.FileInfo) {
			if time.After(thresholdTime) {
				isTooOld = false
				break
			}
		}
		if isTooOld {
			atomic.AddInt64(&c.Statistics.skippedFiles, 1)
			c.debugf("Skipping old file %s", info.path)
			return
		}
	}
	if c.MaxFileSize > 0 &&
		c.MaxFileSize*MB < info.Size() {
		atomic.AddInt64(&c.Statistics.skippedFiles, 1)
		c.debugf("Skipping big file %s", info.path)
		return
	}
	var extensionWanted bool
	for _, extension := range c.FileExtensions {
		if strings.HasSuffix(info.path, extension) {
			extensionWanted = true
			break
		}
	}
	if !extensionWanted && len(c.FileExtensions) > 0 {
		c.debugf("Skipping file %s with unwanted extension", info.path)
		atomic.AddInt64(&c.Statistics.skippedFiles, 1)
		return
	}
	f, err := os.Open(info.path)
	if err != nil {
		c.logger.Printf("Could not open file %s: %v\n", info.path, err)
		atomic.AddInt64(&c.Statistics.fileErrors, 1)
		return
	}
	defer f.Close()

	var urlParams = url.Values{}
	if c.Source != "" {
		urlParams.Add("source", c.Source)
	}

	var apiEndpoint string
	if c.Sync {
		apiEndpoint = "api/checkAsync"
	} else {
		apiEndpoint = "api/check"
	}

	url := fmt.Sprintf("%s/%s?%s", c.Server, apiEndpoint, urlParams.Encode())

	multipartReader, multipartWriter := io.Pipe()
	w := multipart.NewWriter(multipartWriter)
	abspath, err := filepath.Abs(info.path)
	if err != nil {
		abspath = info.path
	}
	go func() {
		fw, err := w.CreateFormFile("file", abspath)
		if err == nil {
			io.Copy(fw, f)
		}
		w.Close()
		multipartWriter.Close()
	}()
	response, err := http.Post(url, w.FormDataContentType(), multipartReader)
	if err != nil {
		if info.retries < 3 {
			c.logger.Printf("Could not send file %s to thunderstorm, will try again: %v", info.path, err)
			info.retries++
			time.Sleep(time.Second)
			return true
		} else {
			c.logger.Printf("Could not send file %s to thunderstorm, canceling it.", info.path)
			atomic.AddInt64(&c.Statistics.uploadErrors, 1)
			return false
		}
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusServiceUnavailable {
		retryTime, err := strconv.Atoi(response.Header.Get("Retry-After"))
		if err == nil {
			retryTime = 30 // Default to 30 seconds cooldown time
		}
		c.logger.Printf("Thunderstorm has no free capacities for file %s, retrying in %d seconds", info.path, retryTime)
		time.Sleep(time.Second * time.Duration(retryTime))
		return true
	}
	if response.StatusCode != http.StatusOK {
		atomic.AddInt64(&c.Statistics.uploadErrors, 1)
		c.logger.Printf("Received error from Thunderstorm for file %s: %v\n", info.path, err)
		return
	}
	atomic.AddInt64(&c.Statistics.uploadedFiles, 1)
	if c.Sync {
		responseBody, _ := ioutil.ReadAll(response.Body)
		c.logger.Printf("Response to file %s: %s", info.path, string(responseBody))
	} else {
		io.Copy(ioutil.Discard, response.Body) // Read the full response to be able to reuse the connection
	}

	if c.Debug {
		c.debugf("File %s processed successfully", info.path)
	}
	return
}
