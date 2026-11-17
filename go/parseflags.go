package main

import (
	"fmt"
	"os"
	"reflect"
	"strings"

	flag "github.com/spf13/pflag"
	"gopkg.in/yaml.v3"
)

var tagsForFullName = []string{"flag", "yaml"}

// wholeValueList is a repeatable string option that takes every occurrence as
// one value. pflag's string slice splits a value at commas, which breaks a path
// or glob that contains one (C:\Users\Smith, John or **/{a,b}/**). As with a
// string slice, the first occurrence replaces the default list.
type wholeValueList struct {
	values  *[]string
	changed bool
}

func (l *wholeValueList) String() string {
	if len(*l.values) == 0 {
		return ""
	}
	return "[" + strings.Join(*l.values, ",") + "]"
}

func (l *wholeValueList) Set(value string) error {
	if !l.changed {
		*l.values = []string{value}
		l.changed = true
	} else {
		*l.values = append(*l.values, value)
	}
	return nil
}

// Type is the name shown in the help, the same as for a string slice.
func (l *wholeValueList) Type() string {
	return "strings"
}

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

			if _, isWhole := structField.Tag.Lookup("whole"); isWhole {
				list, isStringList := reflectConfig.Field(i).Addr().Interface().(*[]string)
				if !isStringList {
					panic("The whole tag needs a string list")
				}
				flags.VarP(&wholeValueList{values: list}, name, structField.Tag.Get("shorthand"), description)
				continue
			}

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

func ReadTemplateFile(defaultFilename string, config interface{}) error {
	var template string
	var templateFlagset = flag.NewFlagSet("collect template", flag.ContinueOnError)
	templateFlagset.StringVarP(&template, "template", "t", "", "Process default scan parameters from this YAML file")
	templateFlagset.Usage = func() {}
	templateFlagset.ParseErrorsWhitelist.UnknownFlags = true
	templateFlagset.Parse(os.Args)
	templateSpecified := template != ""
	if !templateSpecified {
		template = defaultFilename
	}
	configSource = ConfigSource{Path: absolutePath(template), Explicit: templateSpecified}
	f, err := os.Open(template)
	if err != nil {
		if templateSpecified {
			return fmt.Errorf("Template file %s could not be opened: %v\n", template, err)
		} else {
			// A missing default template is not an error; main logs that none was found.
			configSource.OpenErr = err
			return nil
		}
	}
	defer f.Close()
	decoder := yaml.NewDecoder(f)
	decoder.KnownFields(true)
	err = decoder.Decode(config)
	if err != nil {
		return fmt.Errorf("Template file %s could not be parsed: %v\n", template, err)
	}
	configSource.Loaded = true
	return nil
}

// unexpectedArguments returns the non-option arguments that follow the program
// name. ParseConfig hands os.Args to the flag set, so the program name is the
// first non-option argument.
func unexpectedArguments(flags *flag.FlagSet) []string {
	args := flags.Args()
	if len(args) == 0 {
		return nil
	}
	return args[1:]
}
