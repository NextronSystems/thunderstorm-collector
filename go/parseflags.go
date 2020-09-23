package main

import (
	"fmt"
	"os"
	"reflect"

	flag "github.com/spf13/pflag"
	"gopkg.in/yaml.v3"
)

var tagsForFullName = []string{"flag", "yaml"}

func CreateFlagset(config interface{}) *flag.FlagSet {
	reflectConfig := reflect.ValueOf(config)
	if reflectConfig.Kind() != reflect.Ptr {
		panic("Must pass pointer to struct containing configuration")
	}
	reflectConfig = reflectConfig.Elem()
	configType := reflectConfig.Type()

	var flags = flag.NewFlagSet("collector arguments", flag.ContinueOnError)
	reflectFlags := reflect.ValueOf(flags)
	var supportedFlagTypes = map[reflect.Type]string{
		reflect.TypeOf(""):       "String",
		reflect.TypeOf(0):        "Int",
		reflect.TypeOf(int64(0)): "Int64",
		reflect.TypeOf(false):    "Bool",
	}
	for i := 0; i < configType.NumField(); i++ {
		structField := configType.Field(i)
		var name string
		for _, tag := range tagsForFullName {
			var tagExists bool
			name, tagExists = structField.Tag.Lookup(tag)
			if tagExists && name != "-" {
				break
			}
		}
		if name != "" {
			description := structField.Tag.Get("description")
			shorthand, hasShorthand := structField.Tag.Lookup("shorthand")

			fieldType := structField.Type
			var nameSuffix string
			if fieldType.Kind() == reflect.Slice {
				fieldType = fieldType.Elem()
				nameSuffix = "Slice"
			}
			nameInFlagsMethod, isSupported := supportedFlagTypes[fieldType]
			if !isSupported {
				panic("Unsupported type in configuration struct")
			}
			var suffix string
			if hasShorthand {
				suffix = "P"
			}
			methodName := nameInFlagsMethod + nameSuffix + "Var" + suffix
			field := reflectConfig.Field(i)
			var methodArgs []reflect.Value
			if hasShorthand {
				methodArgs = []reflect.Value{
					field.Addr(),
					reflect.ValueOf(name),
					reflect.ValueOf(shorthand),
					field,
					reflect.ValueOf(description)}
			} else {
				methodArgs = []reflect.Value{
					field.Addr(),
					reflect.ValueOf(name),
					field,
					reflect.ValueOf(description)}
			}
			reflectFlags.MethodByName(methodName).Call(methodArgs)
			_, isHidden := structField.Tag.Lookup("hidden")
			if isHidden {
				flags.MarkHidden(name)
			}
		}
	}
	return flags
}

func ReadTemplateFile(config interface{}) error {
	var template string
	var templateFlagset = flag.NewFlagSet("collect template", flag.ContinueOnError)
	templateFlagset.StringVarP(&template, "template", "t", "", "Process default scan parameters from this YAML file")
	templateFlagset.Usage = func() {}
	templateFlagset.ParseErrorsWhitelist.UnknownFlags = true
	templateFlagset.Parse(os.Args)
	if template != "" {
		f, err := os.Open(template)
		if err != nil {
			return fmt.Errorf("Template file %s could not be opened: %w\n", template, err)
		}
		defer f.Close()
		decoder := yaml.NewDecoder(f)
		decoder.KnownFields(true)
		err = decoder.Decode(config)
		if err != nil {
			return fmt.Errorf("Template file %s could not be parsed: %w\n", template, err)
		}
	}
	return nil
}
