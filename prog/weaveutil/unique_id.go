package main

import (
	"fmt"

	"github.com/weaveworks/weave/common"
)

func uniqueID(args []string) error {
	if len(args) != 2 {
		cmdUsage("unique-id", "<db-prefix> <host-root>")
	}
	dbPrefix := args[0]
	hostRoot := args[1]
	uid, err := common.GetSystemPeerName(dbPrefix, hostRoot)
	if err != nil {
		return err
	}
	fmt.Printf(uid)
	return nil
}
