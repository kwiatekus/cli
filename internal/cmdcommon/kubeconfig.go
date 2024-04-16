package cmdcommon

import (
	"github.com/kyma-project/cli.v3/internal/kube"
	"github.com/spf13/cobra"
)

// KubeClientConfig allows to setup kubeconfig flag and use it to create kube.Client
type KubeClientConfig struct {
	Kubeconfig string
	KubeClient kube.Client
}

func (kcc *KubeClientConfig) AddFlag(cmd *cobra.Command) {
	cmd.Flags().StringVar(&kcc.Kubeconfig, "kubeconfig", "", "Path to the Kyma kubecongig file.")

	_ = cmd.MarkFlagRequired("kubeconfig")
}

func (kcc *KubeClientConfig) Complete() error {
	var err error
	kcc.KubeClient, err = kube.NewClient(kcc.Kubeconfig)

	return err
}